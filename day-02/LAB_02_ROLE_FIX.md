# Lab 2 - Role Permission Issue & Fix

## Problem Identified

**The root cause**: The script was trying to use `S3EventLambdaRole` from Lab 1, but:
- Lab 1 was never executed in your environment
- The role `S3EventLambdaRole` did NOT exist in your AWS account
- Without the role, the Lambda function couldn't be created with proper permissions
- Even if created, event source mapping would fail because the role didn't have SQS permissions

## Error Message
```
An error occurred (InvalidParameterValueException) when calling the 
CreateEventSourceMapping operation: The function execution role does 
not have permissions to call ReceiveMessage on SQS
```

## Solution Implemented

### What Changed in lab-02.sh:

1. **Auto-create Lambda role (Step 0.5)**
   - If `S3EventLambdaRole` doesn't exist, the script now creates it
   - Creates proper trust relationship with Lambda service
   - Attaches basic Lambda execution policy

2. **Attach SQS & S3 permissions (Step 2.5)**
   - Explicitly attaches `AmazonSQSFullAccess` policy
   - Explicitly attaches `AmazonS3FullAccess` policy
   - Waits 60 seconds for IAM eventual consistency

3. **Better error handling (Step 4)**
   - Verifies policies are attached before creating event source mapping
   - Provides troubleshooting steps if it fails
   - Clear success/failure messaging

### Why 60-Second Wait is Critical

AWS IAM has "eventual consistency":
- When you attach a policy, it takes time to propagate
- Different AWS services may see the change at different times
- Lambda event source mapping validates the role permissions immediately
- If you don't wait long enough, the validation fails even though the policy is "attached"

## How to Verify the Fix Works

After running lab-02.sh:

1. **Check role was created:**
   ```bash
   aws iam get-role --role-name S3EventLambdaRole
   ```

2. **Check policies are attached:**
   ```bash
   aws iam list-attached-role-policies --role-name S3EventLambdaRole
   ```
   
   You should see:
   - `AmazonSQSFullAccess`
   - `AmazonS3FullAccess`
   - `AWSLambdaBasicExecutionRole`

3. **Check event source mapping was created:**
   ```bash
   aws lambda list-event-source-mappings --event-source-arn arn:aws:sqs:us-east-1:463183325212:clickstream-events
   ```

4. **Check Lambda received messages:**
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/Lambda \
     --metric-name Invocations \
     --dimensions Name=FunctionName,Value=sqs-clickstream-consumer \
     --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
     --period 300 --statistics Sum
   ```

## Key Lessons

✅ **Always create required resources** - Don't assume previous labs were completed  
✅ **Validate prerequisites** - Check role existence before using it  
✅ **IAM eventual consistency** - Always wait 60+ seconds after policy changes  
✅ **Clear error messages** - Help users troubleshoot when things fail  
✅ **Idempotent scripts** - Script can be run multiple times safely  

## Lab 2 Complete!

Once lab-02.sh runs successfully, you should see:
- ✅ SQS queue created
- ✅ Lambda functions created with proper role
- ✅ Event source mapping created
- ✅ 100 clickstream events sent to SQS
- ✅ Lambda processing events and writing JSON to S3
- ✅ Files appearing in `s3://my-datalake-lab-alok/processed/clickstream/`
