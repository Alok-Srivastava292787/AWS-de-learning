# Lab 2 Quick Reference Guide

## Running the Lab

### In Git Bash Terminal
```bash
cd /c/gitrepo/AWS/day-01
./lab-02.sh
```

## What Happens When You Run It

1. **Creates SQS Queue** - `clickstream-events`
2. **Deploys Lambda Function** - `sqs-clickstream-consumer` (Python 3.12)
3. **Sets up Event Mapping** - SQS triggers Lambda with batches of 10 messages
4. **Generates 100 Events** - Simulated clickstream data
5. **Processes in Lambda** - Masks PII, adds timestamp
6. **Writes to S3** - JSON files in partitioned structure
7. **Validates Output** - Checks S3 and displays sample data

## Expected Execution Time
**~3-5 minutes**

### Timeline
- Queue creation: 5-10 seconds
- Lambda deployment: 10-15 seconds
- Data generation: 10-20 seconds
- Processing delay: 20-30 seconds (batching window + processing)
- S3 delivery: 10-15 seconds
- Validation: 10-20 seconds

## Environment Variables (from ../.env)

The script uses these from the parent `.env` file:
- `BUCKET_NAME` - S3 bucket for output (default: my-datalake-lab-alok)
- `REGION` - AWS region (default: us-east-1)
- `LAMBDA_ROLE_ARN` - IAM role for Lambda (from Lab 1)

## Validation Checklist

After running, verify with these commands:

```bash
# 1. Check SQS Queue Created
aws sqs list-queues --region us-east-1

# 2. Get Queue URL
QUEUE_URL=$(aws sqs get-queue-url --queue-name clickstream-events --region us-east-1 --query 'QueueUrl' --output text)
echo $QUEUE_URL

# 3. Check Queue Attributes
aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names All

# 4. Check Lambda Function
aws lambda list-functions --region us-east-1 | grep sqs-clickstream

# 5. Check Event Source Mapping
aws lambda list-event-source-mappings --function-name sqs-clickstream-consumer

# 6. Check S3 Output
aws s3 ls s3://my-datalake-lab-alok/processed/clickstream/ --recursive

# 7. Download and View Sample File
aws s3 ls s3://my-datalake-lab-alok/processed/clickstream/ --recursive | grep '.json' | head -1
# Copy the file path and run:
aws s3 cp s3://my-datalake-lab-alok/processed/clickstream/year=2026/month=04/batch-*.json - | head -100
```

## Files Created

### AWS Resources
- SQS Queue: `clickstream-events`
- Lambda Function: `sqs-clickstream-consumer`
- Lambda Role Policy: S3 write permissions
- Event Source Mapping: SQS → Lambda

### Local Files (in /tmp/)
- `/tmp/sqs_consumer.py` - Lambda function code
- `/tmp/sqs_consumer.zip` - Packaged Lambda function
- `/tmp/producer.py` - Data generator script
- `/tmp/sample.json` - Downloaded sample output

### S3 Output
- `s3://my-datalake-lab-alok/processed/clickstream/year=2026/month=04/batch-*.json`

## Data Sample

### Input Event
```json
{
  "user_id": "u0015",
  "event": "purchase",
  "page": "checkout",
  "session_id": "sess-7823",
  "email": "u0015@example.com",
  "ts": 1712973615
}
```

### Output Event (after Lambda processing)
```json
{
  "user_id": "u0015",
  "event": "purchase",
  "page": "checkout",
  "session_id": "sess-7823",
  "email": "u***@example.com",
  "ts": 1712973615,
  "ingestion_ts": 1712973620
}
```

### Changes Made
- `email` masked: `u***@example.com` (PII protection)
- `ingestion_ts` added: Timestamp when Lambda processed it

## Troubleshooting Commands

### Check Script Execution
```bash
# View most recent log entries
aws logs tail /aws/lambda/sqs-clickstream-consumer --max-items 20

# Follow logs in real-time
aws logs tail /aws/lambda/sqs-clickstream-consumer --follow

# Check for errors
aws logs filter-log-events --log-group-name /aws/lambda/sqs-clickstream-consumer --filter-pattern "ERROR"
```

### Check Queue Status
```bash
# Get queue attributes
aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names All

# Check for messages still in queue
aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names ApproximateNumberOfMessages

# Sample a message (doesn't delete it)
aws sqs receive-message --queue-url $QUEUE_URL --max-number-of-messages 1 --wait-time-seconds 0
```

### Check Lambda Status
```bash
# Get function details
aws lambda get-function --function-name sqs-clickstream-consumer

# Get function configuration
aws lambda get-function-configuration --function-name sqs-clickstream-consumer

# List all functions
aws lambda list-functions | grep clickstream
```

### Check S3 Output
```bash
# List all files
aws s3 ls s3://my-datalake-lab-alok/processed/clickstream/ --recursive

# Count JSON files
aws s3 ls s3://my-datalake-lab-alok/processed/clickstream/ --recursive | grep '.json' | wc -l

# Get total size
aws s3 ls s3://my-datalake-lab-alok/processed/clickstream/ --recursive --summarize --human-readable
```

## Common Issues & Fixes

### "Queue may already exist, continuing..."
✓ Normal - Script handles idempotency, just recreating existing queue

### "Function may already exist, updating..."
✓ Normal - Lambda function already deployed, safely updating

### No JSON files in S3
1. Wait 30+ seconds (batching window is 5 seconds)
2. Check Lambda logs: `aws logs tail /aws/lambda/sqs-clickstream-consumer`
3. Verify S3 bucket exists: `aws s3 ls | grep my-datalake`

### Lambda errors in logs
Check IAM role permissions:
```bash
aws iam list-attached-role-policies --role-name S3EventLambdaRole
aws iam list-role-policies --role-name S3EventLambdaRole
```

## Key Parameters

### SQS Queue Settings
- **VisibilityTimeout**: 300 seconds (5 min) - How long messages hidden after processing
- **MessageRetentionPeriod**: 1209600 seconds (14 days) - How long messages stored

### Lambda Settings
- **BatchSize**: 10 - Process 10 SQS messages at a time
- **MaximumBatchingWindowInSeconds**: 5 - Wait up to 5 seconds to fill a batch
- **Timeout**: 60 seconds - Max time per invocation
- **Memory**: 256 MB - Memory allocation

### Data Partitioning
```
s3://bucket/processed/clickstream/year=YYYY/month=MM/batch-TIMESTAMP.json
```

## Next Steps

1. ✓ Run lab-02.sh
2. ✓ Verify S3 output
3. → Proceed to Lab 3 (data transformation/enrichment)
4. → Add metrics and monitoring
5. → Scale up to production data volumes

---

**Last Updated:** April 13, 2026  
**Shell:** Git Bash  
**Status:** Ready to run
