# Lab 2 - Modified: SQS Alternative to Kinesis

## Overview
Lab 02 has been modified to use **Amazon SQS (Simple Queue Service)** instead of Kinesis Data Streams, since Kinesis is not available in your AWS account.

## What Changed

### Original Architecture (Kinesis)
```
Clickstream Producer → Kinesis Stream → Firehose → Lambda Transform → S3 (Parquet)
```

### New Architecture (SQS)
```
Clickstream Producer → SQS Queue → Lambda Consumer → S3 (JSON)
```

## Key Modifications

### 1. **Step 1: Queue Creation**
- **Old:** `aws kinesis create-stream --stream-name clickstream-events --shard-count 2`
- **New:** `aws sqs create-queue --queue-name clickstream-events`
- **Benefits:** SQS is simpler, available in all accounts, and requires no configuration

### 2. **Step 2: Glue Database (Removed)**
- Removed Glue database creation since we're using JSON instead of Parquet
- Simplifies the pipeline and removes unnecessary AWS service dependencies

### 3. **Step 3: Lambda Transform Function (Simplified)**
- **Old:** `firehose_transform.py` - Complex base64 encoding/decoding for Firehose
- **New:** `sqs_consumer.py` - Simple JSON processing that:
  - Reads messages from SQS
  - Masks email PII
  - Adds ingestion timestamp
  - Writes JSON directly to S3

### 4. **Step 4: Delivery Stream (Replaced)**
- **Old:** Complex Firehose delivery stream with Kinesis source, Glue schema, and Lambda processing
- **New:** Simple Lambda-based consumer with SQS event source mapping
  - Batch size: 10 messages
  - Window: 5 seconds
  - Automatically triggered when messages arrive

### 5. **Step 5: Data Producer (Updated)**
- **Old:** Uses `kinesis.put_records()` with Partition Key
- **New:** Uses `sqs.send_message()` with MessageGroupId
- Messages are JSON formatted and sent directly to SQS

### 6. **Step 6: Monitoring (Updated)**
- **Old:** Kinesis and Firehose metrics
- **New:** SQS and Lambda metrics:
  - `AWS/SQS` - NumberOfMessagesSent, NumberOfMessagesReceived
  - `AWS/Lambda` - Invocations, Duration

### 7. **Step 7: Validation (Updated)**
- **Old:** Validates Parquet files with PyArrow
- **New:** Validates JSON files with standard JSON parsing
- Checks Lambda execution logs for troubleshooting

## Running the Modified Lab

### Prerequisites
```powershell
# Verify credentials
aws sts get-caller-identity

# Verify SQS is available (should work in any account)
aws sqs list-queues --region us-east-1
```

### Run the Lab
```bash
cd C:\gitrepo\AWS\day-01

# On Windows with bash:
bash lab-02.sh

# Or on PowerShell:
wsl bash lab-02.sh
```

## Expected Output

1. **SQS Queue Created**
   - Queue URL: `https://sqs.us-east-1.amazonaws.com/463183325212/clickstream-events`

2. **Lambda Function Deployed**
   - Function Name: `sqs-clickstream-consumer`
   - Runtime: Python 3.12

3. **100 Messages Sent to SQS**
   - Each message contains clickstream event data

4. **Lambda Processes Messages**
   - Batches of 10 messages processed every 5 seconds
   - Email field masked for privacy (e.g., `u@***@example.com`)
   - Timestamp added to each record

5. **JSON Files Delivered to S3**
   - Location: `s3://my-datalake-lab-alok/processed/clickstream/year=2026/month=04/`
   - Format: JSON array with processed records

## Example Output Message

```json
[
  {
    "user_id": "u0001",
    "event": "view",
    "page": "home",
    "session_id": "sess-1234",
    "email": "u***@example.com",
    "ts": 1744592000,
    "ingestion_ts": 1744592015
  }
]
```

## Advantages of SQS Over Kinesis

| Feature | Kinesis | SQS |
|---------|---------|-----|
| **Availability** | Limited (subscription required) | All accounts ✓ |
| **Setup Complexity** | Complex (streams, shards) | Simple (create queue) |
| **Cost** | Pay per shard | Pay per message |
| **Use Case** | Real-time streaming analytics | Reliable message queuing |
| **Processing Latency** | < 1 second | 5-60 seconds (configurable) |
| **Throughput** | High (2 MB/s per shard) | Very high (1M msgs/min) |

## Troubleshooting

### No JSON Files Appearing in S3

1. **Check SQS Queue**
   ```powershell
   aws sqs get-queue-attributes --queue-url https://sqs.us-east-1.amazonaws.com/463183325212/clickstream-events --attribute-names All
   ```

2. **Check Lambda Logs**
   ```powershell
   aws logs tail /aws/lambda/sqs-clickstream-consumer --follow
   ```

3. **Check Lambda Function**
   ```powershell
   aws lambda get-function --function-name sqs-clickstream-consumer
   ```

### Messages Not Being Processed

1. **Verify Event Source Mapping**
   ```powershell
   aws lambda list-event-source-mappings --function-name sqs-clickstream-consumer
   ```

2. **Check Lambda Execution Role Permissions**
   ```powershell
   aws iam list-role-policies --role-name S3EventLambdaRole
   aws iam list-attached-role-policies --role-name S3EventLambdaRole
   ```

## Cleanup

To delete all resources created by this lab:

```bash
# Delete SQS Queue
aws sqs delete-queue --queue-url https://sqs.us-east-1.amazonaws.com/463183325212/clickstream-events

# Delete Lambda Function
aws lambda delete-function --function-name sqs-clickstream-consumer

# Delete Lambda Event Source Mapping (if needed)
aws lambda delete-event-source-mapping --uuid <uuid-from-list-event-source-mappings>

# Delete S3 Objects
aws s3 rm s3://my-datalake-lab-alok/processed/clickstream/ --recursive
```

## Additional Notes

- The SQS queue is created with default settings (unlimited retention)
- Messages are set to be visible for 300 seconds (5 minutes) before retry
- Lambda function has a 60-second timeout per invocation
- Email masking keeps first character visible for tracking (e.g., `j***@example.com`)

---

**Migration Date:** April 13, 2026  
**Original Lab:** Kinesis + Firehose + Parquet  
**Modified Lab:** SQS + Lambda + JSON  
**Status:** ✓ Ready to run
