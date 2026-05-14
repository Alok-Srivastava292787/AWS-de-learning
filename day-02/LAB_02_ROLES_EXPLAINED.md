# Lab 2 - IAM Roles & Permissions Explained

## Roles Used in Lab 2 SQS Pipeline

### 1. Lambda Execution Role: `S3EventLambdaRole`

**What it is:**
- The role that the Lambda function **assumes** when it runs
- Defines what AWS resources Lambda can access
- Created automatically if it doesn't exist (by lab-02.sh Step 0.5)

**Where it's defined:**
- `.env` file: `LAMBDA_ROLE_NAME=S3EventLambdaRole`
- `.env` file: `LAMBDA_ROLE_ARN=arn:aws:iam::463183325212:role/S3EventLambdaRole`

**Permissions it has:**
- `service-role/AWSLambdaBasicExecutionRole` - CloudWatch logging
- `AmazonSQSFullAccess` - Read messages from SQS (attached in lab-02.sh Step 2.5)
- `AmazonS3FullAccess` - Write files to S3 (attached in lab-02.sh Step 2.5)

**Used for:**
```bash
aws lambda create-function \
  --function-name sqs-clickstream-consumer \
  --role arn:aws:iam::463183325212:role/S3EventLambdaRole \
  ...
```

### 2. SQS Queue: `clickstream-events`

**What it is:**
- An AWS Simple Queue Service (SQS) queue
- Stores messages sent by the producer
- Messages are processed by Lambda in batches

**Where it's defined:**
- `.env` file: `SQS_QUEUE_NAME=clickstream-events`
- `.env` file: `SQS_QUEUE_ARN=arn:aws:sqs:us-east-1:463183325212:clickstream-events`

**Configuration:**
- VisibilityTimeout: 300 seconds (5 minutes)
- MessageRetentionPeriod: 1209600 seconds (14 days)
- Batch Size: 10 messages
- Batch Window: 5 seconds

**Used for:**
```bash
# Create event source mapping (connects SQS to Lambda)
aws lambda create-event-source-mapping \
  --event-source-arn arn:aws:sqs:us-east-1:463183325212:clickstream-events \
  --function-name sqs-clickstream-consumer \
  --batch-size 10 \
  --maximum-batching-window-in-seconds 5
```

## How They Work Together

```
┌─────────────────────────────────────────────────────────────────┐
│                    Lab 2 SQS Pipeline                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Producer Script                                             │
│     └─> Sends 100 JSON messages to SQS queue                   │
│                                                                 │
│  2. SQS Queue: clickstream-events                              │
│     └─> Stores messages temporarily                            │
│     └─> Batches messages (10 msgs, 5 sec window)              │
│                                                                 │
│  3. Lambda Function: sqs-clickstream-consumer                  │
│     └─> Triggered by SQS event source mapping                  │
│     └─> Assumes: S3EventLambdaRole                            │
│     └─> Uses SQS permissions to read messages                  │
│     └─> Uses S3 permissions to write files                     │
│     └─> Processes each message:                                │
│         • Parses JSON                                          │
│         • Masks email: user@example.com → u***@example.com     │
│         • Adds ingestion_ts timestamp                          │
│         • Writes batch as JSON to S3                           │
│                                                                 │
│  4. S3 Bucket: my-datalake-lab-alok                           │
│     └─> Location: s3://bucket/processed/clickstream/           │
│     └─> Structure: year=YYYY/month=MM/batch-{timestamp}.json   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Roles Summary Table

| Component | Role/ARN | Purpose |
|-----------|----------|---------|
| **Lambda Execution** | `S3EventLambdaRole` | Lambda assumes this to read SQS & write S3 |
| **SQS Queue** | `clickstream-events` | Source of events for Lambda |
| **Queue ARN** | `arn:aws:sqs:us-east-1:...` | Used for event source mapping |
| **Bucket** | `my-datalake-lab-alok` | Destination for processed data |

## How to Verify the Setup

### 1. Check Lambda role exists and has permissions:
```bash
aws iam get-role --role-name S3EventLambdaRole
aws iam list-attached-role-policies --role-name S3EventLambdaRole
```

Expected policies:
- AWSLambdaBasicExecutionRole
- AmazonSQSFullAccess
- AmazonS3FullAccess

### 2. Check SQS queue exists:
```bash
aws sqs get-queue-url --queue-name clickstream-events
aws sqs get-queue-attributes --queue-url <URL> --attribute-names All
```

### 3. Check event source mapping was created:
```bash
aws lambda list-event-source-mappings \
  --event-source-arn arn:aws:sqs:us-east-1:463183325212:clickstream-events
```

### 4. Check Lambda function has correct role:
```bash
aws lambda get-function-configuration --function-name sqs-clickstream-consumer | grep Role
```

Should show: `S3EventLambdaRole`

## Why the 60-Second Wait is Critical

When you attach an IAM policy:
1. The policy is stored in AWS IAM
2. AWS services are notified of the change
3. Each service replicates the change internally
4. This replication can take up to 60+ seconds

**If you create event source mapping too early:**
- Lambda hasn't received the notification yet
- Event source mapping validation fails
- Error: "The function execution role does not have permissions to call ReceiveMessage on SQS"

**Solution:** Lab 2 script waits 60 seconds after attaching policies before creating event source mapping.

## Key Takeaway

The **only role you really need** for Lab 2 is:
- ✅ **S3EventLambdaRole** (Lambda execution role)

The FirehoseDeliveryRole was legacy code from the Kinesis->Firehose design and has been removed.
