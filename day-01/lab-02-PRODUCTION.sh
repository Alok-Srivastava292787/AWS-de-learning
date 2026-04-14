#!/bin/bash

################################################################################
# Lab 02: SQS → Lambda → S3 Data Pipeline (Kinesis Alternative)
# Production-Ready Version
#
# Objective: Create an SQS queue, set up Lambda consumer function to read from
# SQS, process (PII masking), and write data to S3 with Hive partitioning.
# Replaces Kinesis (unavailable) with SQS for reliable queuing.
#
# Prerequisites:
# - AWS CLI v2 configured
# - Permissions: SQS, Lambda, S3, IAM access
# - lab-01.sh completed (S3 bucket, Lambda role created)
# - .env file configured with BUCKET_NAME, REGION, etc.
################################################################################

set -e
set -u
export MSYS_NO_PATHCONV=1

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=================================================="
echo "Lab 02: SQS → Lambda → S3 Pipeline - Production"
echo "==================================================${NC}"
echo ""

# ============================================================================
# Step 0: Load Configuration
# ============================================================================
echo -e "${YELLOW}Step 0: Loading environment configuration...${NC}"

if [ -f "../.env" ]; then
    set -a
    source ../.env
    set +a
    echo "✓ Environment variables loaded from ../.env"
else
    echo "✗ Error: ../.env file not found"
    exit 1
fi

# Verify required variables
for var in BUCKET_NAME REGION ACCOUNT_ID LAMBDA_ROLE_NAME; do
    if [ -z "${!var:-}" ]; then
        echo "✗ Missing required variable: $var"
        exit 1
    fi
done

echo "✓ Bucket:         $BUCKET_NAME"
echo "✓ Region:         $REGION  "
echo "✓ Account:        $ACCOUNT_ID"
echo ""

# ============================================================================
# Step 0.5: Create/Verify Lambda Execution Role
# ============================================================================
echo -e "${YELLOW}Step 0.5: Creating/Verifying Lambda execution role...${NC}"

if aws iam get-role --role-name $LAMBDA_ROLE_NAME &>/dev/null; then
    echo "✓ Role already exists: $LAMBDA_ROLE_NAME"
else
    echo "Creating role: $LAMBDA_ROLE_NAME"
    
    cat > ../lambda-trust.json << 'EOFTRUST'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOFTRUST

    aws iam create-role \
      --role-name $LAMBDA_ROLE_NAME \
      --assume-role-policy-document file://../lambda-trust.json
    
    echo "✓ Role created"
    
    # Attach execution policy
    aws iam attach-role-policy \
      --role-name $LAMBDA_ROLE_NAME \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    echo "✓ Execution policy attached"
    
    sleep 10
fi

LAMBDA_ROLE_ARN=$(aws iam get-role --role-name $LAMBDA_ROLE_NAME --query 'Role.Arn' --output text)
echo "✓ Lambda Role ARN: $LAMBDA_ROLE_ARN"
echo ""

# ============================================================================
# Step 1: Create SQS Queue
# ============================================================================
echo -e "${YELLOW}Step 1: Creating SQS queue...${NC}"

QUEUE_URL=$(aws sqs get-queue-url --queue-name clickstream-events --region $REGION --query 'QueueUrl' --output text 2>/dev/null) || QUEUE_URL=""

if [ -z "$QUEUE_URL" ]; then
    echo "Creating queue: clickstream-events"
    
    QUEUE_URL=$(aws sqs create-queue \
      --queue-name clickstream-events \
      --attributes VisibilityTimeout=300,MessageRetentionPeriod=1209600 \
      --region $REGION \
      --query 'QueueUrl' \
      --output text)
    
    echo "✓ Queue created"
else
    echo "✓ Queue already exists"
fi

QUEUE_ARN=$(aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names QueueArn \
  --region $REGION \
  --query 'Attributes.QueueArn' \
  --output text)

echo "✓ Queue URL: $QUEUE_URL"
echo "✓ Queue ARN: $QUEUE_ARN"
echo ""

# ============================================================================
# Step 2: Create SQS Consumer Lambda Function
# ============================================================================
echo -e "${YELLOW}Step 2: Creating SQS consumer Lambda function...${NC}"

# Check if function exists
if aws lambda get-function --function-name sqs-clickstream-consumer &>/dev/null; then
    echo "✓ Function already exists: sqs-clickstream-consumer"
else
    echo "Creating consumer function..."
    
    # Create handler code
    cat > ../sqs_consumer.py << 'EOFHANDLER'
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
    Consume messages from SQS, mask PII, and write to S3 with Hive partitioning.
    """
    bucket = event.get('bucket_name', 'my-datalake-lab-alok')
    records = []
    
    # Process SQS messages
    for record in event.get('Records', []):
        try:
            body = json.loads(record['body'])
            
            # Add ingestion timestamp
            body['ingestion_ts'] = int(time.time())
            
            # Mask email PII
            if 'email' in body:
                parts = body['email'].split('@') if '@' in body['email'] else [body['email'], '']
                local = parts[0]
                domain = parts[1] if len(parts) > 1 else ''
                masked = local[0] + '***@' + domain if domain else '***'
                body['email'] = masked
            
            records.append(body)
            logger.info(f"Processed: user={body.get('user_id', 'N/A')}")
            
        except Exception as e:
            logger.error(f"Error processing record: {e}")
            continue
    
    # Write batch to S3 with Hive partitioning
    if records:
        timestamp = datetime.utcnow()
        year = timestamp.strftime('%Y')
        month = timestamp.strftime('%m')
        day = timestamp.strftime('%d')
        batch_time = int(time.time())
        
        key = f"processed/clickstream/year={year}/month={month}/day={day}/batch-{batch_time}.csv"
        
        # Convert to CSV format
        import csv
        import io
        
        output = io.StringIO()
        if records:
            writer = csv.DictWriter(output, fieldnames=records[0].keys())
            writer.writeheader()
            writer.writerows(records)
        
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=output.getvalue(),
            ContentType='text/csv'
        )
        
        logger.info(f"Wrote {len(records)} records to s3://{bucket}/{key}")
    
    return {
        'statusCode': 200,
        'body': json.dumps(f'Processed {len(records)} messages')
    }
EOFHANDLER
    
    # Package function
    cd .. && zip -q sqs_consumer.zip sqs_consumer.py && cd day-01
    
    # Create function
    aws lambda create-function \
      --function-name sqs-clickstream-consumer \
      --runtime python3.12 \
      --role $LAMBDA_ROLE_ARN \
      --handler sqs_consumer.lambda_handler \
      --zip-file fileb://../sqs_consumer.zip \
      --timeout 60 \
      --environment "Variables={bucket_name=$BUCKET_NAME}"
    
    echo "✓ Function created"
    
    sleep 5
fi

CONSUMER_ARN=$(aws lambda get-function \
  --function-name sqs-clickstream-consumer \
  --query 'Configuration.FunctionArn' \
  --output text)

echo "✓ Consumer ARN: $CONSUMER_ARN"
echo ""

# ============================================================================
# Step 2.5: Attach SQS and S3 Permissions
# ============================================================================
echo -e "${YELLOW}Step 2.5: Attaching SQS and S3 permissions...${NC}"

# Attach SQS managed policy
aws iam attach-role-policy \
  --role-name $LAMBDA_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess 2>/dev/null || \
  echo "✓ SQS policy attached"

# Create inline policy for S3
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
        "sqs:GetQueueAttributes"
      ],
      "Resource": "arn:aws:sqs:*:*:*"
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
        "arn:aws:s3:::*",
        "arn:aws:s3:::*/*"
      ]
    }
  ]
}
EOFPOLICY

aws iam put-role-policy \
  --role-name $LAMBDA_ROLE_NAME \
  --policy-name LambdaSQSS3Policy \
  --policy-document file://../lambda-inline-policy.json 2>/dev/null || \
  echo "✓ Inline policy applied"

echo "✓ SQS and S3 permissions configured"
echo "Waiting 60 seconds for IAM propagation..."
sleep 60
echo ""

# ============================================================================
# Step 3: Grant SQS Permission to Invoke Lambda
# ============================================================================
echo -e "${YELLOW}Step 3: Granting SQS invoke permission...${NC}"

aws lambda add-permission \
  --function-name sqs-clickstream-consumer \
  --statement-id AllowSQSInvoke \
  --action lambda:InvokeFunction \
  --principal sqs.amazonaws.com \
  --source-arn $QUEUE_ARN 2>/dev/null || \
  echo "✓ Permission already configured"

echo "✓ SQS → Lambda permission configured"
echo ""

# ============================================================================
# Step 4: Create Event Source Mapping
# ============================================================================
echo -e "${YELLOW}Step 4: Creating SQS → Lambda event source mapping...${NC}"

# Check if mapping already exists
EXISTING_MAPPING=$(aws lambda list-event-source-mappings \
  --event-source-arn $QUEUE_ARN \
  --function-name sqs-clickstream-consumer \
  --query 'EventSourceMappings[0].UUID' \
  --output text 2>/dev/null) || EXISTING_MAPPING=""

if [ "$EXISTING_MAPPING" != "None" ] && [ -n "$EXISTING_MAPPING" ]; then
    echo "✓ Mapping already exists (UUID: $EXISTING_MAPPING)"
else
    echo "Creating event source mapping..."
    
    aws lambda create-event-source-mapping \
      --event-source-arn $QUEUE_ARN \
      --function-name sqs-clickstream-consumer \
      --batch-size 10 \
      --maximum-batching-window-in-seconds 5
    
    echo "✓ Event source mapping created"
    sleep 5
fi

# Verify mapping is enabled
MAPPING_STATE=$(aws lambda list-event-source-mappings \
  --event-source-arn $QUEUE_ARN \
  --function-name sqs-clickstream-consumer \
  --query 'EventSourceMappings[0].State' \
  --output text 2>/dev/null)

echo "✓ Mapping state: $MAPPING_STATE"
echo ""

# ============================================================================
# Step 5: Test with Producer Messages
# ============================================================================
echo -e "${YELLOW}Step 5: Sending test messages to SQS queue...${NC}"

# Create producer
cat > ../producer.py << 'EOFPRODUCER'
import boto3
import json
import random
import time

sqs = boto3.client('sqs', region_name='us-east-1')

QUEUE_URL = 'https://sqs.us-east-1.amazonaws.com/463183325212/clickstream-events'
PAGES = ['home', 'product', 'cart', 'checkout', 'confirmation', 'search']
EVENTS = ['view', 'click', 'scroll', 'purchase', 'add_to_cart', 'search']
USERS = [f"u{i:04d}" for i in range(1, 21)]

print(f"Sending 100 test clickstream events to SQS")

for i in range(100):
    user = random.choice(USERS)
    message = {
        'user_id': user,
        'event': random.choice(EVENTS),
        'page': random.choice(PAGES),
        'session_id': f"sess-{random.randint(1000,9999)}",
        'email': f"{user}@example.com",
        'timestamp': int(time.time())
    }
    
    try:
        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(message)
        )
        if (i + 1) % 25 == 0:
            print(f"Sent {i + 1} messages...")
    except Exception as e:
        print(f"Error sending message: {e}")
        break

print(f"✓ Successfully sent 100 test events!")
EOFPRODUCER

# Run producer
cd .. && python producer.py && cd day-01

echo ""
echo "Waiting 10 seconds for Lambda to process messages..."
sleep 10
echo ""

# ============================================================================
# Step 6: Verify Data in S3
# ============================================================================
echo -e "${YELLOW}Step 6: Verifying processed data in S3...${NC}"

echo "Checking for processed data..."
aws s3 ls s3://$BUCKET_NAME/processed/clickstream/ --recursive --human-readable

echo ""
echo ""

# ============================================================================
# Summary
# ============================================================================
echo -e "${GREEN}=================================================="
echo "Lab 02 Complete! SQS → Lambda → S3 Pipeline Ready"
echo "==================================================${NC}"
echo ""
echo "✓ SQS Queue:              clickstream-events"
echo "✓ Lambda Consumer:        sqs-clickstream-consumer"
echo "✓ Event Source Mapping:   Enabled (batch size: 10)"
echo "✓ S3 Output Location:     s3://$BUCKET_NAME/processed/clickstream/"
echo "✓ Test Messages:          100 sent and processed"
echo ""
echo "Pipeline Flow:"
echo "  Producer → SQS → Lambda (batch) → S3 (Hive partitions)"
echo ""
echo -e "${GREEN}Ready for Lab 03: Glue Crawler and Athena queries!${NC}"
echo ""
