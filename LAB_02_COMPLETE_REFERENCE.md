# Lab 2 Complete Reference Guide

## What Lab 2 Does

Implements a **SQS → Lambda → S3 JSON** data pipeline that:
1. Receives clickstream events via SQS
2. Processes events (PII masking, timestamp injection)
3. Writes processed data to S3 with partitioning

## Prerequisites (Auto-Created by Lab 2)

✅ **SQS Queue** - `clickstream-events`  
✅ **Lambda Execution Role** - `S3EventLambdaRole`  
✅ **Lambda Functions** - `sqs-clickstream-consumer`  
✅ **Event Source Mapping** - SQS → Lambda connection  

## Environment Variables Required

All defined in `../.env`:

```properties
# Core Configuration
BUCKET_NAME=my-datalake-lab-alok           # S3 data lake bucket
REGION=us-east-1                           # AWS region
ACCOUNT_ID=463183325212                    # Your AWS account

# Lambda Role (Auto-created if doesn't exist)
LAMBDA_ROLE_NAME=S3EventLambdaRole
LAMBDA_ROLE_ARN=arn:aws:iam::463183325212:role/S3EventLambdaRole

# SQS Queue
SQS_QUEUE_NAME=clickstream-events
SQS_QUEUE_ARN=arn:aws:sqs:us-east-1:463183325212:clickstream-events

# Lambda Configuration
LAB02_LAMBDA_FUNCTION=sqs-clickstream-consumer
LAB02_LAMBDA_HANDLER=sqs_consumer.lambda_handler
LAB02_BATCH_SIZE=10
LAB02_BATCH_WINDOW_SECONDS=5
LAB02_OUTPUT_PREFIX=processed/clickstream/
```

## Lab 2 Execution Steps

### Step 0: Load Environment
- Sources `../.env` file
- Exports all variables for use in script

### Step 0.5: Create/Verify Lambda Role
- Checks if `S3EventLambdaRole` exists
- **If missing**: Creates role with Lambda trust relationship
- Attaches `AWSLambdaBasicExecutionRole` for CloudWatch logging

### Step 1: Create SQS Queue
```bash
aws sqs create-queue \
  --queue-name clickstream-events \
  --attributes VisibilityTimeout=300,MessageRetentionPeriod=1209600
```
- Visibility Timeout: 300 seconds (time for Lambda to process)
- Retention: 14 days (message lifespan)

### Step 2: Create Lambda Functions
Two functions are created:

**Function 1: firehose-pii-masker**
- Legacy/unused (left for reference)
- Original Firehose transformation logic

**Function 2: sqs-clickstream-consumer** (MAIN)
- Triggered by SQS events
- Reads from SQS queue
- Processes event batches (10 messages max, 5-second window)
- **Processing steps:**
  1. Parses JSON from SQS message body
  2. Adds `ingestion_ts` (current timestamp)
  3. Masks email: `user0001@example.com` → `u***@example.com`
  4. Writes batch to S3 as JSON

### Step 2.5: Attach Permissions to Lambda Role
```bash
aws iam attach-role-policy --role-name S3EventLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess

aws iam attach-role-policy --role-name S3EventLambdaRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
```
- ⏳ **CRITICAL**: Waits 60 seconds for IAM propagation
- This is why it takes so long!

### Step 3: Create Event Source Mapping
```bash
aws lambda create-event-source-mapping \
  --event-source-arn $QUEUE_ARN \
  --function-name sqs-clickstream-consumer \
  --batch-size 10 \
  --maximum-batching-window-in-seconds 5
```
- Connects SQS queue to Lambda function
- Batches messages: max 10 or 5-second window
- This step was **failing** before we had SQS permissions

### Step 4: Grant Lambda Permission to Invoke from SQS
```bash
aws lambda add-permission \
  --function-name sqs-clickstream-consumer \
  --statement-id AllowSQSInvoke \
  --action lambda:InvokeFunction \
  --principal sqs.amazonaws.com \
  --source-arn $QUEUE_ARN
```

### Step 5: Run Producer Script
```python
# Sends 100 clickstream events to SQS
for i in range(100):
    message = {
        'user_id': 'u0001',
        'event': 'click',
        'page': 'home',
        'session_id': 'sess-1234',
        'email': 'u0001@example.com',
        'ts': 1681234567
    }
    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(message))
```

### Step 6: Monitor CloudWatch Metrics
Checks:
- **SQS NumberOfMessagesSent** - Should see ~100
- **Lambda Invocations** - Should see batch invocations
- **SQS NumberOfMessagesReceived** - Should see messages being consumed

### Step 7: Validate S3 Output
- Waits 15-30 seconds for Lambda to process
- Lists files in `s3://bucket/processed/clickstream/`
- Expected structure:
  ```
  processed/clickstream/
  ├── year=2026/
  │   └── month=04/
  │       ├── batch-1681234567.json
  │       ├── batch-1681234568.json
  │       └── ...
  ```

## Expected Output Structure

### S3 JSON Files

Each batch contains array of processed events:

```json
[
  {
    "user_id": "u0001",
    "event": "click",
    "page": "home",
    "session_id": "sess-1234",
    "email": "u***@example.com",      // ← MASKED
    "ts": 1681234567,
    "ingestion_ts": 1681234570        // ← ADDED by Lambda
  },
  {
    "user_id": "u0002",
    "event": "view",
    "page": "product",
    "session_id": "sess-5678",
    "email": "u***@example.com",      // ← MASKED
    "ts": 1681234568,
    "ingestion_ts": 1681234571        // ← ADDED by Lambda
  }
  // ... more records
]
```

## CloudWatch Metrics Expected

After script completion (10-15 minutes):

| Metric | Namespace | Expected Value |
|--------|-----------|-----------------|
| NumberOfMessagesSent | AWS/SQS | ~118 (100 test + 18 attempts) |
| NumberOfMessagesReceived | AWS/SQS | ~100+ (consumed by Lambda) |
| Invocations | AWS/Lambda | ~10 (batches of 10 messages) |
| Duration | AWS/Lambda | 500-2000 ms (per batch) |
| Errors | AWS/Lambda | 0 (should be none) |

## Troubleshooting

### Issue: "The function execution role does not have permissions..."
**Solution:**
- Verify SQS policy is attached: `aws iam list-attached-role-policies --role-name S3EventLambdaRole`
- Ensure 60-second wait completed
- Try running script again

### Issue: No Lambda invocations
**Symptoms:**
- Metrics show 0 invocations
- Event source mapping failed
**Solutions:**
1. Check event source mapping: `aws lambda list-event-source-mappings`
2. Check Lambda role has SQS permissions
3. Check queue has messages: `aws sqs receive-message --queue-url <URL>`

### Issue: No files in S3
**Symptoms:**
- SQS messages consumed but no S3 files
**Solutions:**
1. Check Lambda logs: `aws logs tail /aws/lambda/sqs-clickstream-consumer`
2. Verify Lambda role has S3 write permission
3. Check bucket exists: `aws s3 ls s3://my-datalake-lab-alok/`

## Success Criteria

✅ Lab 2 is successful when:
1. SQS queue `clickstream-events` exists
2. Lambda function `sqs-clickstream-consumer` created
3. Event source mapping created (SQS→Lambda)
4. 100 test messages sent to SQS
5. Lambda processes all messages (10 batches)
6. JSON files appear in S3: `processed/clickstream/year=YYYY/month=MM/`
7. Email fields are masked
8. ingestion_ts fields added

## Next Steps

After Lab 2 succeeds:
- **Lab 3**: Create Glue crawler to catalog the data
- **Lab 4**: Query data with Athena
- **Lab 5**: Advanced analytics with SageMaker

## Cost Analysis

**Lab 2 Pipeline Monthly Cost (estimated):**
- SQS: ~$1.00 (100,000 requests)
- Lambda: ~$0.20 (100 invocations, 256MB, 5s each)
- S3 Storage: ~$0.02 (100 files, 1KB each)
- **Total: ~$1.22/month** ✅ Very cheap!

(Original Kinesis design would have cost ~$400/month)
