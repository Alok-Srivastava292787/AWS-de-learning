#!/bin/bash

################################################################################
# Lab 01: S3 Data Lake Setup with Lambda Event Notifications
# Production-Ready Version
# 
# Objective: Create a versioned S3 data lake bucket with Hive-style partitioned 
# prefixes, attach S3 event notifications to Lambda, test with sample data, 
# and apply lifecycle policies for cost management.
#
# Prerequisites:
# - AWS CLI v2 installed and configured (aws configure)
# - Python 3.12+ installed locally
# - Permissions: S3FullAccess, LambdaFullAccess, IAMFullAccess
# - Region: us-east-1
################################################################################

set -e  # Exit on any error
set -u  # Exit on undefined variables
export MSYS_NO_PATHCONV=1

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=================================================="
echo "Lab 01: S3 Data Lake Setup - Production Ready"
echo "=================================================="
echo ""

# ============================================================================
# Step 0: Load Configuration
# ============================================================================
echo -e "${YELLOW}Step 0: Loading configuration...${NC}"

export BUCKET_NAME="my-datalake-lab-alok"
export REGION="us-east-1"
export LAMBDA_ROLE_NAME="S3EventLambdaRole"
export LAMBDA_FUNCTION_NAME="s3-ingestion-trigger"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "✓ Bucket:         $BUCKET_NAME"
echo "✓ Region:         $REGION"
echo "✓ Account ID:     $ACCOUNT_ID"
echo ""

# ============================================================================
# Step 1: Create and Configure S3 Data Lake Bucket
# ============================================================================
echo -e "${YELLOW}Step 1: Creating S3 data lake bucket...${NC}"

# Check if bucket already exists
if aws s3api head-bucket --bucket $BUCKET_NAME 2>/dev/null; then
    echo "✓ Bucket already exists: $BUCKET_NAME"
else
    echo "Creating bucket: $BUCKET_NAME"
    aws s3api create-bucket --bucket $BUCKET_NAME --region $REGION
    echo "✓ Bucket created successfully"
fi

# Enable versioning
echo "Enabling versioning..."
aws s3api put-bucket-versioning --bucket $BUCKET_NAME --versioning-configuration Status=Enabled
echo "✓ Versioning enabled"

# Block all public access (security best practice)
echo "Blocking public access..."
aws s3api put-public-access-block \
  --bucket $BUCKET_NAME \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "✓ Public access blocked"
echo ""

# ============================================================================
# Step 2: Create Hive-Style Folder Structure
# ============================================================================
echo -e "${YELLOW}Step 2: Creating Hive-style partition structure...${NC}"

# Create partition prefixes
aws s3api put-object --bucket $BUCKET_NAME --key raw/source=csv/year=2024/month=01/.keep
aws s3api put-object --bucket $BUCKET_NAME --key raw/source=api/year=2024/month=01/.keep
aws s3api put-object --bucket $BUCKET_NAME --key processed/year=2024/month=01/.keep
aws s3api put-object --bucket $BUCKET_NAME --key errors/.keep

echo "✓ Folder structure created"
echo ""

# ============================================================================
# Step 3: Create Lambda Execution IAM Role
# ============================================================================
echo -e "${YELLOW}Step 3: Creating Lambda execution role...${NC}"

# Check if role already exists
if aws iam get-role --role-name $LAMBDA_ROLE_NAME 2>/dev/null; then
    echo "✓ Role already exists: $LAMBDA_ROLE_NAME"
    LAMBDA_ROLE_ARN=$(aws iam get-role --role-name $LAMBDA_ROLE_NAME --query 'Role.Arn' --output text)
else
    echo "Creating IAM role..."
    
    # Create trust policy document
    cat > ../lambda-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
    
    # Create the role
    aws iam create-role \
      --role-name $LAMBDA_ROLE_NAME \
      --assume-role-policy-document file://../lambda-trust.json
    
    # Attach required policies
    aws iam attach-role-policy \
      --role-name $LAMBDA_ROLE_NAME \
      --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    
    aws iam attach-role-policy \
      --role-name $LAMBDA_ROLE_NAME \
      --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
    
    # Get role ARN
    LAMBDA_ROLE_ARN=$(aws iam get-role --role-name $LAMBDA_ROLE_NAME --query 'Role.Arn' --output text)
    
    echo "✓ Role created: $LAMBDA_ROLE_NAME"
    
    # Wait for IAM eventual consistency
    sleep 10
fi

echo "✓ Lambda Role ARN: $LAMBDA_ROLE_ARN"
echo ""

# ============================================================================
# Step 4: Create and Deploy Lambda Function
# ============================================================================
echo -e "${YELLOW}Step 4: Creating Lambda function...${NC}"

# Check if function already exists
if aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME 2>/dev/null; then
    echo "✓ Lambda function already exists: $LAMBDA_FUNCTION_NAME"
else
    echo "Creating Lambda handler..."
    
    # Create the Lambda handler code
    cat > ../s3_event_handler.py << 'EOF'
import json
import logging
import time
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Process S3 event notifications.
    Logs bucket, key, object size, and event time.
    """
    records_processed = 0
    
    for record in event.get('Records', []):
        try:
            bucket = record['s3']['bucket']['name']
            key = record['s3']['object']['key']
            size = record['s3']['object'].get('size', 0)
            event_time = record['eventTime']
            
            logger.info(
                f"S3 EVENT | bucket={bucket} | key={key} | size={size}B | time={event_time}"
            )
            
            # TODO: Add Glue crawler trigger or Step Functions integration here
            records_processed += 1
        except Exception as e:
            logger.error(f"Error processing record: {e}")
            continue
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': f'Processed {records_processed} S3 event(s)',
            'timestamp': datetime.utcnow().isoformat()
        })
    }
EOF
    
    # Package the function
    cd .. && zip -q s3_event_handler.zip s3_event_handler.py && cd day-01
    
    # Create the function
    aws lambda create-function \
      --function-name $LAMBDA_FUNCTION_NAME \
      --runtime python3.12 \
      --role $LAMBDA_ROLE_ARN \
      --handler s3_event_handler.lambda_handler \
      --zip-file fileb://../s3_event_handler.zip \
      --timeout 30 \
      --environment "Variables={BUCKET_NAME=$BUCKET_NAME}"
    
    echo "✓ Lambda function created: $LAMBDA_FUNCTION_NAME"
fi

# Get Lambda ARN
LAMBDA_ARN=$(aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME \
  --query 'Configuration.FunctionArn' --output text)
echo "✓ Lambda ARN: $LAMBDA_ARN"
echo ""

# ============================================================================
# Step 5: Grant S3 Permission to Invoke Lambda
# ============================================================================
echo -e "${YELLOW}Step 5: Granting S3 permission to invoke Lambda...${NC}"

aws lambda add-permission \
  --function-name $LAMBDA_FUNCTION_NAME \
  --statement-id s3-invoke-permission \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::$BUCKET_NAME \
  --source-account $ACCOUNT_ID 2>/dev/null || echo "✓ Permission already exists or was already granted"

echo "✓ S3 permission configured"
echo ""

# ============================================================================
# Step 6: Configure S3 Event Notification
# ============================================================================
echo -e "${YELLOW}Step 6: Configuring S3 event notifications...${NC}"

# Create notification configuration
cat > ../notification.json << EOF
{
  "LambdaFunctionConfigurations": [{
    "Id": "s3-to-lambda",
    "LambdaFunctionArn": "$LAMBDA_ARN",
    "Events": ["s3:ObjectCreated:*"],
    "Filter": {
      "Key": {
        "FilterRules": [{"Name": "prefix", "Value": "raw/"}]
      }
    }
  }]
}
EOF

aws s3api put-bucket-notification-configuration \
  --bucket $BUCKET_NAME \
  --notification-configuration file://../notification.json

echo "✓ Event notification configured"

# Verify configuration
echo "Verifying configuration..."
aws s3api get-bucket-notification-configuration --bucket $BUCKET_NAME --query 'LambdaFunctionConfigurations[0].{Id:Id,Events:Events,Prefix:Filter.Key.FilterRules[0].Value}'
echo ""

# ============================================================================
# Step 7: Test End-to-End Pipeline
# ============================================================================
echo -e "${YELLOW}Step 7: Testing end-to-end pipeline...${NC}"

# Create sample data
cat > ../sample_events.csv << 'EOF'
user_id,event,page,timestamp
u001,click,home,2024-01-15T10:00:00Z
u002,view,product,2024-01-15T10:01:00Z
u003,purchase,checkout,2024-01-15T10:02:00Z
u004,add_to_cart,product,2024-01-15T10:03:00Z
u005,search,home,2024-01-15T10:04:00Z
EOF

echo "Sample data:"
head -2 ../sample_events.csv
echo ""

# Upload sample file (triggers Lambda)
echo "Uploading sample file to: s3://$BUCKET_NAME/raw/source=csv/year=2024/month=01/"
aws s3 cp ../sample_events.csv \
  s3://$BUCKET_NAME/raw/source=csv/year=2024/month=01/sample_events.csv
echo "✓ Upload complete"

# Wait for Lambda to execute
echo "Waiting for Lambda to process event (5 seconds)..."
sleep 5

# Check CloudWatch Logs
LOG_GROUP="/aws/lambda/$LAMBDA_FUNCTION_NAME"
LOG_STREAM=$(aws logs describe-log-streams \
  --log-group-name $LOG_GROUP \
  --order-by LastEventTime \
  --descending \
  --query 'logStreams[0].logStreamName' \
  --output text 2>/dev/null || echo "")

if [ -z "$LOG_STREAM" ] || [ "$LOG_STREAM" = "None" ]; then
    echo "⚠ No log stream found yet. Lambda may still be starting."
else
    echo "Checking Lambda logs..."
    aws logs get-log-events \
      --log-group-name $LOG_GROUP \
      --log-stream-name $LOG_STREAM \
      --query 'events[*].message' \
      --output text | grep -i "S3 EVENT" || echo "No S3 event logs found yet"
fi

echo ""

# ============================================================================
# Step 8: Apply S3 Lifecycle Policy
# ============================================================================
echo -e "${YELLOW}Step 8: Applying S3 lifecycle policy...${NC}"

# Create lifecycle configuration
cat > ../lifecycle.json << 'EOF'
{
  "Rules": [
    {
      "ID": "archive-raw-data",
      "Status": "Enabled",
      "Filter": { "Prefix": "raw/" },
      "Transitions": [
        { "Days": 30,  "StorageClass": "STANDARD_IA" },
        { "Days": 90,  "StorageClass": "GLACIER" },
        { "Days": 180, "StorageClass": "DEEP_ARCHIVE" }
      ],
      "Expiration": { "Days": 365 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 90 }
    },
    {
      "ID": "archive-processed-data",
      "Status": "Enabled",
      "Filter": { "Prefix": "processed/" },
      "Transitions": [
        { "Days": 60,  "StorageClass": "STANDARD_IA" },
        { "Days": 180, "StorageClass": "GLACIER" }
      ],
      "Expiration": { "Days": 730 }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket $BUCKET_NAME \
  --lifecycle-configuration file://../lifecycle.json

echo "✓ Lifecycle policy applied"

# Verify
echo "Lifecycle configuration:"
aws s3api get-bucket-lifecycle-configuration --bucket $BUCKET_NAME \
  --query 'Rules[*].{ID:ID,Status:Status,Prefix:Filter.Prefix}' --output table
echo ""

# ============================================================================
# Summary
# ============================================================================
echo -e "${GREEN}=================================================="
echo "Lab 01 Complete! Summary:"
echo "==================================================${NC}"
echo ""
echo "✓ S3 Bucket:              $BUCKET_NAME"
echo "✓ Versioning:             Enabled"
echo "✓ Public Access:          Blocked"
echo "✓ Partition Structure:    Created (raw/, processed/, errors/)"
echo "✓ Lambda Role:            $LAMBDA_ROLE_NAME"
echo "✓ Lambda Function:        $LAMBDA_FUNCTION_NAME"
echo "✓ Event Notification:     Configured (raw/* → Lambda)"
echo "✓ Lifecycle Policy:       Applied (raw→STANDARD_IA→GLACIER→DEEP_ARCHIVE)"
echo "✓ Sample Test:            Executed"
echo ""
echo -e "${GREEN}AWS S3 Data Lake is ready for ingestion!${NC}"
echo ""
