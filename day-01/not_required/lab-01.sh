#!/bin/bash
##Objective: Create a versioned S3 data lake bucket with Hive-style partitioned prefixes, attach an S3 
##event notification to a Lambda function, test with sample data uploads, and apply a lifecycle policy 
##for cost management. 
##Pre-requisites: 
##• AWS CLI v2 installed and configured (aws configure) with a user/role having S3FullAccess and 
##LambdaFullAccess 
##• Python 3.8+ installed locally for producing sample data files 
##• An AWS region selected – use us-east-1 throughout this lab for consistency 

set -e
set -u  # Exit on undefined variables
#trap "echo 'Script failed at line $LINENO'" ERR
export MSYS_NO_PATHCONV=1
echo $MSYS_NO_PATHCONV
## Step 1: Create and configure the S3 data lake bucket
export BUCKET_NAME="my-datalake-lab-alok" 
export REGION="us-east-1" 
echo $BUCKET_NAME
echo $REGION
## Create the bucket ---------Done--------- 
 aws s3api create-bucket --bucket $BUCKET_NAME --region $REGION 
 
## Enable versioning  ---------Done---------
 aws s3api put-bucket-versioning --bucket $BUCKET_NAME --versioning-configuration Status=Enabled

## Block all public access (security best practice) ---------Done---------
 aws s3api put-public-access-block --bucket $BUCKET_NAME --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" 



## Step 2: Create the Hive-style folder structure (landing zone prefixes)
## Create raw landing zone prefixes for two sources ---------Done---------
 aws s3api put-object --bucket $BUCKET_NAME --key raw/source=csv/year=2024/month=01/.keep
 aws s3api put-object --bucket $BUCKET_NAME --key raw/source=api/year=2024/month=01/.keep
 aws s3api put-object --bucket $BUCKET_NAME --key processed/year=2024/month=01/.keep
 aws s3api put-object --bucket $BUCKET_NAME --key errors/.keep

## Verify structure
 aws s3 ls s3://$BUCKET_NAME/ --recursive



## Step 3: Create the Lambda execution IAM role
##  Create the trust policy document 
#cat > ./lambda-trust.json << 'EOF'
#{
#  "Version": "2012-10-17",
#  "Statement": [{
#    "Effect": "Allow",
#    "Principal": { "Service": "lambda.amazonaws.com" },
#    "Action": "sts:AssumeRole"
#  }]
#}
#EOF

## Create the role ---------Done---------
 aws iam create-role --role-name S3EventLambdaRole --assume-role-policy-document file://../lambda-trust.json

## Attach basic Lambda execution (CloudWatch Logs) policy  ---------Done---------
aws iam attach-role-policy --role-name S3EventLambdaRole --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

## Allow Lambda to read from S3 (for validation)  ---------Done---------
aws iam attach-role-policy   --role-name S3EventLambdaRole --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess

## Capture the role ARN for later  ---------Done---------
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name S3EventLambdaRole --query 'Role.Arn' --output text)
echo "Role ARN: $LAMBDA_ROLE_ARN"


##Step 4: Write and deploy the Lambda function
## Write the Lambda handler  ---------Done---------
#cat > ./s3_event_handler.py << 'EOF'
#import json, logging
#logger = logging.getLogger()
#logger.setLevel(logging.INFO)
#
#def lambda_handler(event, context):
#    for record in event.get('Records', []):
#        bucket = record['s3']['bucket']['name']
#        key    = record['s3']['object']['key']
#        size   = record['s3']['object'].get('size', 0)
#        etime  = record['eventTime']
#        logger.info(f"NEW OBJECT | bucket={bucket} | key={key} | size={size}B |
#time={etime}")
#        # TODO: trigger Glue crawler or Step Functions here
#    return {'statusCode': 200, 'body': f"Processed {len(event['Records'])}
#record(s)"}
#EOF

## Package and deploy  ---------Done---------
## cd /tmp && zip s3_handler.zip s3_event_handler.py 

 aws lambda create-function  --function-name ./lambda/s3-ingestion-trigger  --runtime python3.12  --role $LAMBDA_ROLE_ARN  --handler s3_event_handler.lambda_handler  --zip-file fileb://./s3_handler.zip  --timeout 30



## Step 5: Grant S3 permission to invoke Lambda  ---------Done---------
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT_ID: $ACCOUNT_ID"
aws lambda add-permission  --function-name s3-ingestion-trigger  --statement-id s3-invoke-permission  --action lambda:InvokeFunction  --principal s3.amazonaws.com  --source-arn arn:aws:s3:::$BUCKET_NAME  --source-account $ACCOUNT_ID


# Step 6: Configure S3 event notification  ---------Done---------
LAMBDA_ARN=$(aws lambda get-function --function-name s3-ingestion-trigger  --query 'Configuration.FunctionArn' --output text) 
echo "Lambda ARN: $LAMBDA_ARN"

#cat > ./notification.json << EOF
#{
#  "LambdaFunctionConfigurations": [{
#    "Id": "s3-to-lambda",
#    "LambdaFunctionArn": "$LAMBDA_ARN",
#    "Events": ["s3:ObjectCreated:*"],
#    "Filter": {
#      "Key": {
#        "FilterRules": [{"Name": "prefix", "Value": "raw/"}]
#      }
#    }
#  }]
#}
#EOF

aws s3api put-bucket-notification-configuration  --bucket $BUCKET_NAME --notification-configuration file://./notification.json

# Verify the configuration was applied
aws s3api get-bucket-notification-configuration --bucket $BUCKET_NAME 


#Step 7: Test the end-to-end pipeline
# Create a sample CSV
#echo "creating sample csv file for upload"
#cat > ./sample_events.csv << 'EOF'
#user_id,event,page,timestamp
#u001,click,home,2024-01-15T10:00:00Z
#u002,view,product,2024-01-15T10:01:00Z
#u003,purchase,checkout,2024-01-15T10:02:00Z
#EOF
#cat ./sample_events.csv

# Upload to the raw/ prefix (this fires the S3 event)
aws s3 cp ./sample_events.csv  s3://$BUCKET_NAME/raw/source=csv/year=2024/month=01/sample_events.csv
#echo "Loaded successfully"

# Wait a few seconds, then check CloudWatch Logs
sleep 5
LOG_GROUP="/aws/lambda/s3-ingestion-trigger"
LOG_STREAM=$(aws logs describe-log-streams --log-group-name $LOG_GROUP  --order-by LastEventTime --descending   --query 'logStreams[0].logStreamName' --output text)
#echo "LOG GROUP: $LOG_GROUP"
#echo "LOG_STREAM: $LOG_STREAM"
#echo "-------Getting log events------------"
echo "Getting log events"
echo "aws logs get-log-events  --log-group-name \"$LOG_GROUP\"  --log-stream-name '$LOG_STREAM'  --query events[*].message --output text"
      aws logs get-log-events  --log-group-name $LOG_GROUP  --log-stream-name $LOG_STREAM  --query events[*].message --output text


##Step 8: Apply S3 Lifecycle policy for cost management 
#Configure a lifecycle rule to automatically transition objects to cheaper storage tiers over time and 
#eventually expire them – essential for cost governance in a real data lake. 
#cat > ../lifecycle.json << 'EOF' 
#{ 
#  "Rules": [{ 
#    "ID": "archive-and-expire-raw-data", 
#    "Status": "Enabled", 
#    "Filter": { "Prefix": "raw/" }, 
#    "Transitions": [ 
#      { "Days": 30,  "StorageClass": "STANDARD_IA" }, 
#      { "Days": 90,  "StorageClass": "GLACIER" }, 
#      { "Days": 180, "StorageClass": "DEEP_ARCHIVE" } 
#    ], 
#    "Expiration": { "Days": 365 }, 
#AWS Data Engineer Associate – Day 1 
#Ingestion Patterns 
#(Batch/Streaming) 
#"NoncurrentVersionExpiration": { "NoncurrentDays": 90 } 
#}] 
#} 
#EOF 
aws s3api put-bucket-lifecycle-configuration --bucket $BUCKET_NAME --lifecycle-configuration file://../lifecycle.json 
# Verify 
aws s3api get-bucket-lifecycle-configuration --bucket $BUCKET_NAME 

