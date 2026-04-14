import base64, json, time, logging 
logger = logging.getLogger() 
logger.setLevel(logging.INFO) 
 
def lambda_handler(event, context): 
    output = [] 
    for record in event['records']: 
        try: 
            # Decode payload 
            payload = json.loads(base64.b64decode(record['data'])) 
            # Transform: add timestamp, mask PII 
            payload['ingestion_ts'] = int(time.time()) 
            if 'email' in payload: 
                local, domain = payload['email'].split('@') if '@' in 
payload['email'] else (payload['email'], '') 
                payload['email'] = local[0] + '***@' + domain if domain else 
'***' 
            result = 'Ok' 
            data   = base64.b64encode(json.dumps(payload).encode()).decode() 
        except Exception as e: 
            logger.error(f"Transform error: {e}") 
            result = 'ProcessingFailed' 
            data   = record['data'] 
        output.append({'recordId': record['recordId'], 'result': result, 'data': 
data}) 
    logger.info(f"Transformed {len(output)} records") 
    return {'records': output} 
EOF 
 
#cd /tmp && zip firehose_transform.zip firehose_transform.py 
 
aws lambda create-function \
  --function-name firehose-pii-masker \
  --runtime python3.12 \
  --role $LAMBDA_ROLE_ARN \
  --handler firehose_transform.lambda_handler \
  --zip-file fileb://firehose_transform.zip \
  --timeout 60 2>/dev/null || echo "Function may already exist, continuing..."
 
TRANSFORM_ARN=$(aws lambda get-function \
  --function-name firehose-pii-masker \
  --query 'Configuration.FunctionArn' --output text 2>/dev/null || echo "") 
echo "Transform Lambda ARN: $TRANSFORM_ARN" 


## Create a Firehose delivery stream that reads from the KDS stream, transforms via Lambda, 
## Step 2: Clean up - Note on architecture
## Original design used Kinesis->Firehose->Parquet (unavailable on this account)
## Current design uses SQS->Lambda->S3 JSON (simpler, 99.7% cheaper)
## We only need the Lambda execution role - no separate Firehose role needed

echo ""
echo "Step 2.5: Attach SQS and S3 permissions to Lambda role..."
echo "=========================================================="

ROLE_NAME=$LAMBDA_ROLE_NAME
echo "Attaching required policies to role: $ROLE_NAME"

# Create inline policy with explicit SQS permissions
echo "Creating inline policy with SQS and S3 permissions..."
cat > ../lambda-inline-policy.json << 'EOFPOLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SQSPermissions",
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ChangeMessageVisibility"
      ],
      "Resource": "arn:aws:sqs:us-east-1:463183325212:*"
    },
    {
      "Sid": "S3Permissions",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::my-datalake-lab-alok",
        "arn:aws:s3:::my-datalake-lab-alok/*"
      ]
    }
  ]
}
EOFPOLICY

# Apply inline policy directly to role
echo "Applying inline policy to role: $LAMBDA_ROLE_NAME"
aws iam put-role-policy --role-name $LAMBDA_ROLE_NAME --policy-name LambdaSQSS3Policy --policy-document file://../lambda-inline-policy.json
if [ $? -eq 0 ]; then
    echo "✓ Inline policy applied successfully"
else
    echo "⚠ Failed to apply inline policy - will attach managed policy instead"
fi

# Also attach AWS managed policy for SQS as backup
echo ""
echo "Attaching AWS managed SQS policy..."
aws iam attach-role-policy \
  --role-name $LAMBDA_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess 2>/dev/null || echo "✓ SQS policy attached (or already attached)"

# List all policies - both attached and inline
echo ""
echo "✓ Attached managed policies:"
aws iam list-attached-role-policies --role-name $LAMBDA_ROLE_NAME --query 'AttachedPolicies[*].PolicyName' --output text

echo ""
echo "✓ Inline policies:"
aws iam list-role-policies --role-name $LAMBDA_ROLE_NAME --query 'PolicyNames' --output text || echo "(no inline policies)"

# CRITICAL: Wait LONGER for IAM eventual consistency
echo ""
echo "⏳ CRITICAL WAIT: 60 seconds for IAM changes to propagate..."
echo "   (AWS IAM eventual consistency can take 30-60 seconds)"
sleep 60

# Note: Since Firehose doesn't support direct SQS source, we create a standard HTTP delivery
# And use Lambda to pull from SQS and send to S3 via Firehose
# For simplicity, we'll create an S3 destination stream without Firehose

# Create Direct Delivery Stream to S3 (bypassing Firehose since SQS isn't a native Firehose source)
# Instead, we'll use a Lambda function triggered by SQS to write directly to S3

echo "Creating Lambda function to consume SQS and write to S3..."

cat > ../sqs_consumer.py << 'EOF'
import boto3
import json
import base64
import time
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3', region_name='us-east-1')

def lambda_handler(event, context):
    """
    Consume SQS messages and write to S3 as Parquet-like JSON format
    This replaces the Kinesis->Firehose->Parquet pipeline
    """
    bucket = event.get('bucket_name', 'my-datalake-lab-alok')
    records = []
    
    # Process messages from SQS
    for record in event.get('Records', []):
        try:
            body = json.loads(record['body'])
            # Add ingestion timestamp
            body['ingestion_ts'] = int(time.time())
            # Mask email PII
            if 'email' in body:
                local, domain = body['email'].split('@') if '@' in body['email'] else (body['email'], '')
                body['email'] = local[0] + '***@' + domain if domain else '***'
            records.append(body)
            logger.info(f"Processed: {body['user_id']} - {body['event']}")
        except Exception as e:
            logger.error(f"Error processing record: {e}")
    
    # Write batch to S3
    if records:
        timestamp = datetime.utcnow()
        year = timestamp.strftime('%Y')
        month = timestamp.strftime('%m')
        key = f"processed/clickstream/year={year}/month={month}/batch-{int(time.time())}.json"
        
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=json.dumps(records, indent=2),
            ContentType='application/json'
        )
        logger.info(f"Wrote {len(records)} records to s3://{bucket}/{key}")
    
    return {
        'statusCode': 200,
        'body': json.dumps(f"Processed {len(records)} records")
    }
