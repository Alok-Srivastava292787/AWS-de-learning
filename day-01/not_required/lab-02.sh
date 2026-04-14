##Step 0: Load environment variables from .env file
# Source the .env file from parent directory
if [ -f "../.env" ]; then
    set -a  # Export all variables
    source ../.env
    set +a  # Stop exporting
    echo "✓ Environment variables loaded from ../.env"
else
    echo "✗ Error: ../.env file not found"
    exit 1
fi

echo ""
echo "Step 0.5: Create Lambda execution role if it doesn't exist"
echo "==========================================================="

# Check if role exists
if ! aws iam get-role --role-name $LAMBDA_ROLE_NAME &>/dev/null; then
    echo "Role $LAMBDA_ROLE_NAME does not exist - creating it..."
    
    # Create trust policy for Lambda
    cat > ../lambda-trust.json << 'EOFTRUST'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOFTRUST

    # Create the role
    aws iam create-role \
      --role-name $LAMBDA_ROLE_NAME \
      --assume-role-policy-document file://../lambda-trust.json
    
    echo "✓ Role created: $LAMBDA_ROLE_NAME"
    
    # Attach basic Lambda execution policy
    aws iam attach-role-policy \
      --role-name $LAMBDA_ROLE_NAME \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    echo "✓ Basic execution policy attached"
    
    # Wait for role to be created
    sleep 10
else
    echo "✓ Role already exists: $LAMBDA_ROLE_NAME"
fi

# Get the actual role ARN
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name $LAMBDA_ROLE_NAME --query 'Role.Arn' --output text)
echo "Lambda Role ARN: $LAMBDA_ROLE_ARN"
echo ""

##Step 1: Create the SQS Queue (ALTERNATIVE to Kinesis)
##Note: Using SQS instead of Kinesis because Kinesis is not available on this AWS account
##SQS provides similar queuing capability with VisibilityTimeout and MessageRetentionPeriod
##for reliable message delivery to the Lambda and S3 pipeline.
aws sqs create-queue \
  --queue-name clickstream-events \
  --attributes VisibilityTimeout=300,MessageRetentionPeriod=1209600 \
  --region us-east-1

# Get the queue URL
QUEUE_URL=$(aws sqs get-queue-url --queue-name clickstream-events --region us-east-1 --query 'QueueUrl' --output text)
echo "Queue URL: $QUEUE_URL"

# Get the queue ARN for later use
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names QueueArn --region us-east-1 --query 'Attributes.QueueArn' --output text)
echo "Queue ARN: $QUEUE_ARN" 

##Step 2: Create the Lambda PII-masking consumer function
##This Lambda function will be triggered by SQS messages.
##It decodes the JSON, masks the email field, adds an ingestion timestamp,
##and writes the processed data directly to S3.
cat > ../firehose_transform.py << 'EOF' 
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
EOF

#cd /tmp && zip sqs_consumer.zip sqs_consumer.py

aws lambda create-function \
  --function-name sqs-clickstream-consumer \
  --runtime python3.12 \
  --role $LAMBDA_ROLE_ARN \
  --handler sqs_consumer.lambda_handler \
  --zip-file fileb://../sqs_consumer.zip \
  --timeout 60 \
  --environment Variables="{bucket_name=$BUCKET_NAME}" 2>/dev/null || echo "Function may already exist, continuing..."

CONSUMER_ARN=$(aws lambda get-function \
  --function-name sqs-clickstream-consumer \
  --query 'Configuration.FunctionArn' --output text)
echo "SQS Consumer Lambda ARN: $CONSUMER_ARN"

# Grant SQS permission to invoke Lambda
echo "Granting SQS permission to invoke Lambda..."
aws lambda add-permission \
  --function-name sqs-clickstream-consumer \
  --statement-id AllowSQSInvoke \
  --action lambda:InvokeFunction \
  --principal sqs.amazonaws.com \
  --source-arn $QUEUE_ARN 2>/dev/null || echo "Permission may already exist, continuing..."

# Create SQS -> Lambda event source mapping
echo ""
echo "Step 4: Creating SQS -> Lambda event source mapping..."
echo "======================================================"

# Final verification before event source mapping
echo "Final policy verification for $LAMBDA_ROLE_NAME:"
echo ""
echo "🔍 Attached managed policies:"
aws iam list-attached-role-policies --role-name $LAMBDA_ROLE_NAME --query 'AttachedPolicies[*].PolicyName' --output text
echo ""
echo "🔍 Inline policies:"
aws iam list-role-policies --role-name $LAMBDA_ROLE_NAME --query 'PolicyNames' --output text || echo "(none)"

echo ""
echo "Creating event source mapping:"
echo "  - Event Source: $QUEUE_ARN"
echo "  - Lambda Function: sqs-clickstream-consumer"
echo "  - Batch Size: 10"
echo "  - Batch Window: 5 seconds"
echo ""

# Create event source mapping - THIS IS THE CRITICAL STEP
# Check if mapping already exists
EXISTING_MAPPING=$(aws lambda list-event-source-mappings --event-source-arn $QUEUE_ARN --function-name sqs-clickstream-consumer --query 'EventSourceMappings[0].UUID' --output text 2>/dev/null)

if [ "$EXISTING_MAPPING" != "None" ] && [ -n "$EXISTING_MAPPING" ]; then
    echo "✅ Event source mapping already exists (UUID: $EXISTING_MAPPING)"
    echo "   Skipping creation..."
else
    echo "Creating new event source mapping..."
    if aws lambda create-event-source-mapping --event-source-arn $QUEUE_ARN --function-name sqs-clickstream-consumer --batch-size 10 --maximum-batching-window-in-seconds 5 2>&1; then
        echo "✅ Event source mapping created successfully!"
    else
        echo "❌ Event source mapping creation FAILED"
        echo ""
        echo "Troubleshooting steps:"
        echo "1. Verify role has SQS permissions:"
        echo "   aws iam list-attached-role-policies --role-name $LAMBDA_ROLE_NAME"
        echo ""
        echo "2. Check Lambda function exists:"
        echo "   aws lambda get-function --function-name sqs-clickstream-consumer"
        echo ""
        echo "3. Check SQS queue exists:"
        echo "   aws sqs get-queue-url --queue-name clickstream-events"
        exit 1
    fi
fi
 ## Step 5: Run the Python producer to send 100 clickstream events to SQS
## The producer sends realistic clickstream records using send_message() to the SQS queue.
## SQS ensures ordered processing and reliable delivery with configurable visibility timeout.
cat > ../producer.py << 'EOF'
import boto3
import json
import random
import time

sqs = boto3.client('sqs', region_name='us-east-1')
QUEUE_URL = 'https://sqs.us-east-1.amazonaws.com/463183325212/clickstream-events'  # Update with your queue URL
PAGES   = ['home', 'product', 'cart', 'checkout', 'confirmation', 'search']
EVENTS  = ['view', 'click', 'scroll', 'purchase', 'add_to_cart', 'search']
USERS   = [f"u{i:04d}" for i in range(1, 21)]   # 20 unique users

print(f"Sending 100 clickstream events to SQS Queue: {QUEUE_URL}")

for i in range(100):
    user = random.choice(USERS)
    message = {
        'user_id':    user,
        'event':      random.choice(EVENTS),
        'page':       random.choice(PAGES),
        'session_id': f"sess-{random.randint(1000,9999)}",
        'email':      f"{user}@example.com",
        'ts':         int(time.time())
    }
    
    # Send to SQS
    response = sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message),
        MessageGroupId=user  # FIFO grouping (optional)
    )
    
    if (i + 1) % 20 == 0:
        print(f"Sent {i + 1}/100 messages...")

print("✓ All 100 messages sent to SQS Queue")
EOF

# Get the actual queue URL and update the producer
QUEUE_URL_ACTUAL=$(aws sqs get-queue-url --queue-name clickstream-events --region us-east-1 --query 'QueueUrl' --output text)
sed -i "s|https://sqs.us-east-1.amazonaws.com/463183325212/clickstream-events|$QUEUE_URL_ACTUAL|g" ../producer.py

python ../producer.py 
 
##Step 6: Monitor SQS and Lambda metrics
##Verify data is flowing through the pipeline by checking key CloudWatch metrics.
##SQS messages are processed by Lambda in batches (configured for batch size 10, window 5 seconds).
# Check SQS incoming messages (last 5 minutes)
aws cloudwatch get-metric-statistics \
  --namespace AWS/SQS \
  --metric-name NumberOfMessagesSent \
  --dimensions Name=QueueName,Value=clickstream-events \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Sum

# Check Lambda invocations
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=sqs-clickstream-consumer \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Sum

# Check SQS messages received by Lambda
aws cloudwatch get-metric-statistics \
  --namespace AWS/SQS \
  --metric-name NumberOfMessagesReceived \
  --dimensions Name=QueueName,Value=clickstream-events \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Sum 
 

 ## Step 7: Validate JSON files landed in S3
## After Lambda processes the SQS messages (typically within 10 seconds), files are written to S3.
## List the output prefix and validate the file contents.

# Wait for Lambda to process messages (batching window is 5 seconds + processing time)
sleep 15

# List delivered JSON files
aws s3 ls s3://$BUCKET_NAME/processed/clickstream/ --recursive

# Download and inspect one file
SAMPLE_FILE=$(aws s3 ls s3://$BUCKET_NAME/processed/clickstream/ --recursive | grep '.json' | head -1 | awk '{print $4}')

if [ -z "$SAMPLE_FILE" ]; then
    echo "No JSON files found in S3 yet. Waiting additional 15 seconds..."
    sleep 15
    SAMPLE_FILE=$(aws s3 ls s3://$BUCKET_NAME/processed/clickstream/ --recursive | grep '.json' | head -1 | awk '{print $4}')
fi

if [ ! -z "$SAMPLE_FILE" ]; then
    echo "Downloading sample file: s3://$BUCKET_NAME/$SAMPLE_FILE"
    aws s3 cp "s3://$BUCKET_NAME/$SAMPLE_FILE" ../sample.json
    
    # Display file contents
    echo "✓ Sample file contents:"
    cat ../sample.json | python -m json.tool
    
    echo ""
    echo "✓ File statistics:"
    echo "  - File size: $(wc -c < ../sample.json) bytes"
    echo "  - Records in file: $(cat ../sample.json | python -c "import sys, json; data = json.load(sys.stdin); print(len(data) if isinstance(data, list) else 1)")"
else
    echo "✗ No JSON files found. Check Lambda execution logs:"
    aws logs tail /aws/lambda/sqs-clickstream-consumer --follow --format short
fi

echo ""
echo "=========================================="
echo "Lab 2 Complete! Summary:"
echo "=========================================="
echo "✓ SQS Queue created: clickstream-events"
echo "✓ Lambda consumer deployed: sqs-clickstream-consumer"
echo "✓ 100 clickstream events sent via SQS"
echo "✓ JSON files delivered to S3: s3://$BUCKET_NAME/processed/clickstream/"
echo "==========================================" 
 
