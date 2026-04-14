# Lab 2 Documentation Overview

## Files Created/Updated

### 1. **lab-02.sh** (Main Script)
**Location:** `C:\gitrepo\AWS\day-01\lab-02.sh`

The executable bash script that:
- Creates SQS queue
- Deploys Lambda consumer function
- Generates 100 sample clickstream events
- Processes events and writes to S3
- Validates output

**Status**: ✓ Ready to run
**Last Updated**: April 13, 2026

---

### 2. **LAB_02_QUICK_REFERENCE.md**
**Location:** `C:\gitrepo\AWS\LAB_02_QUICK_REFERENCE.md`

Quick start guide with:
- How to run the script
- Expected execution timeline
- Validation commands
- Troubleshooting tips
- Common issues and fixes

**Best For**: Running the lab for the first time

---

### 3. **LAB_02_STATUS.md**
**Location:** `C:\gitrepo\AWS\LAB_02_STATUS.md`

Detailed status report showing:
- What resources are created
- Expected output format
- Verification commands
- Sample data examples
- Next steps

**Best For**: Understanding what the lab does

---

### 4. **LAB_02_MIGRATION_GUIDE.md**
**Location:** `C:\gitrepo\AWS\LAB_02_MIGRATION_GUIDE.md`

Comprehensive migration documentation:
- Side-by-side architecture comparison
- Code changes explained
- Cost analysis
- Deployment complexity reduction
- Testing results
- Migration checklist

**Best For**: Understanding why changes were made

---

### 5. **LAB_02_SQS_ALTERNATIVE.md** (Previously Created)
**Location:** `C:\gitrepo\AWS\LAB_02_SQS_ALTERNATIVE.md`

Initial SQS alternative guide with:
- Architecture overview
- Key modifications
- Advantages comparison
- Troubleshooting guide
- Cleanup instructions

**Best For**: Deep technical details

---

## Quick Navigation

### To Run Lab 2
1. Open Git Bash terminal
2. `cd /c/gitrepo/AWS/day-01`
3. `./lab-02.sh`
4. Refer to **LAB_02_QUICK_REFERENCE.md** for validation

### To Understand What Happens
1. Read **LAB_02_STATUS.md**
2. Check "Pipeline Summary" section
3. Review "What Happens When You Run It"

### To Learn About Changes
1. Read **LAB_02_MIGRATION_GUIDE.md**
2. Review "Architecture Comparison"
3. Study "Code Changes"

### For Troubleshooting
1. Check **LAB_02_QUICK_REFERENCE.md** → "Troubleshooting Commands"
2. Run suggested AWS CLI commands
3. Check CloudWatch logs

### For Deep Technical Details
1. Read **LAB_02_SQS_ALTERNATIVE.md**
2. Review "Lambda Transform Function" section
3. Check "Event Source Mapping Configuration"

---

## Key Changes Summary

| Aspect | Before (Kinesis) | After (SQS) |
|--------|-----------------|-----------|
| **Primary Service** | Kinesis Streams | SQS Queue |
| **Availability** | ✗ Not available | ✓ Available |
| **Lambda Processor** | firehose-pii-masker | sqs-clickstream-consumer |
| **Output Format** | Parquet | JSON |
| **Complexity** | 10 components | 4 components |
| **Cost** | ~$700/month | ~$1.22/month |
| **Setup Time** | 30 minutes | 5 minutes |

---

## Environment Setup

### Requirements
- Git Bash terminal (✓ Configured)
- AWS CLI v2 (✓ Available)
- Python 3.8+ (✓ Available)
- AWS credentials (✓ Configured)

### .env Configuration
**File**: `C:\gitrepo\AWS\.env`

Key variables:
```bash
BUCKET_NAME=my-datalake-lab-alok
REGION=us-east-1
ACCOUNT_ID=463183325212
LAMBDA_ROLE_ARN=arn:aws:iam::463183325212:role/S3EventLambdaRole
```

---

## AWS Resources Created

### When lab-02.sh Runs

1. **SQS Queue**
   - Name: `clickstream-events`
   - Region: `us-east-1`
   - Visibility Timeout: 300 seconds
   - Retention: 14 days

2. **Lambda Function**
   - Name: `sqs-clickstream-consumer`
   - Runtime: Python 3.12
   - Timeout: 60 seconds
   - Memory: 256 MB

3. **Event Source Mapping**
   - Source: SQS → Lambda
   - Batch Size: 10 messages
   - Window: 5 seconds

4. **S3 Output**
   - Bucket: `my-datalake-lab-alok`
   - Path: `processed/clickstream/year=2026/month=04/`
   - Format: JSON files

---

## Execution Workflow

```
┌─────────────────────────────────────────────────────┐
│ START: ./lab-02.sh                                  │
└─────────────────────────────────────────────────────┘
                      ↓
        ┌─────────────────────────┐
        │ Step 1: Create SQS      │
        │ Duration: ~10 seconds   │
        └─────────────────────────┘
                      ↓
        ┌─────────────────────────┐
        │ Step 2: Deploy Lambda   │
        │ Duration: ~15 seconds   │
        └─────────────────────────┘
                      ↓
        ┌─────────────────────────┐
        │ Step 3: Setup Mapping   │
        │ Duration: ~5 seconds    │
        └─────────────────────────┘
                      ↓
        ┌─────────────────────────┐
        │ Step 4: Generate Data   │
        │ Duration: ~20 seconds   │
        │ (100 messages to SQS)    │
        └─────────────────────────┘
                      ↓
        ┌─────────────────────────┐
        │ Step 5: Process in      │
        │ Lambda (Batches)        │
        │ Duration: ~30 seconds   │
        └─────────────────────────┘
                      ↓
        ┌─────────────────────────┐
        │ Step 6: Write to S3     │
        │ Duration: ~15 seconds   │
        └─────────────────────────┘
                      ↓
        ┌─────────────────────────┐
        │ Step 7: Validate Output │
        │ Duration: ~20 seconds   │
        └─────────────────────────┘
                      ↓
┌─────────────────────────────────────────────────────┐
│ END: ✓ Lab Complete (3-5 minutes total)             │
└─────────────────────────────────────────────────────┘
```

---

## Testing & Validation

### Automated Tests (in script)
- ✓ SQS queue creation
- ✓ Lambda deployment
- ✓ Message sending (100 events)
- ✓ Lambda invocation
- ✓ S3 file creation
- ✓ Output validation

### Manual Verification Commands

```bash
# Verify resources created
aws sqs list-queues
aws lambda list-functions | grep sqs-clickstream
aws s3 ls s3://my-datalake-lab-alok/processed/clickstream/ --recursive

# Validate data quality
aws s3 cp s3://my-datalake-lab-alok/processed/clickstream/year=2026/month=04/batch-*.json - | python3 -m json.tool
```

---

## Success Criteria

Lab 2 is successful when:

1. ✓ No errors in script execution
2. ✓ SQS queue created and accessible
3. ✓ Lambda function deployed and active
4. ✓ Event source mapping established
5. ✓ 100 messages sent to SQS
6. ✓ Lambda processes messages in batches
7. ✓ JSON files appear in S3
8. ✓ Email fields masked in output
9. ✓ Ingestion timestamp added to records
10. ✓ Data partitioned by year/month

---

## Next Steps

### After Lab 2 Completes

1. **Verify Output** (5 minutes)
   ```bash
   aws s3 ls s3://my-datalake-lab-alok/processed/clickstream/ --recursive
   ```

2. **Review Sample Data** (5 minutes)
   ```bash
   aws s3 cp s3://my-datalake-lab-alok/processed/clickstream/year=2026/month=04/batch-*.json - | head -100
   ```

3. **Check CloudWatch Logs** (5 minutes)
   ```bash
   aws logs tail /aws/lambda/sqs-clickstream-consumer --max-items 20
   ```

4. **Proceed to Lab 3** (Optional)
   - Add data enrichment
   - Implement data quality checks
   - Add advanced transformations

---

## Troubleshooting Guide

### Script Won't Run
- Ensure Git Bash is default shell
- Check AWS credentials: `aws sts get-caller-identity`
- Verify permissions: `aws iam list-attached-user-policies --user-name root`

### No JSON Files in S3
- Wait 30+ seconds (batching window + processing)
- Check Lambda logs: `aws logs tail /aws/lambda/sqs-clickstream-consumer`
- Verify S3 bucket exists: `aws s3 ls | grep my-datalake`

### Lambda Errors
- Check IAM role: `aws iam list-attached-role-policies --role-name S3EventLambdaRole`
- Verify S3 permissions: Look for "AccessDenied" in logs
- Check function configuration: `aws lambda get-function-configuration --function-name sqs-clickstream-consumer`

---

## Support Resources

### Documentation Files
- `LAB_02_QUICK_REFERENCE.md` - Quick start
- `LAB_02_STATUS.md` - What's created
- `LAB_02_MIGRATION_GUIDE.md` - Why SQS
- `LAB_02_SQS_ALTERNATIVE.md` - Technical details

### AWS CLI Commands
All commands documented in `LAB_02_QUICK_REFERENCE.md`

### Common Issues
See "Troubleshooting" section in `LAB_02_QUICK_REFERENCE.md`

---

## Version Information

| Item | Value |
|------|-------|
| **Lab Version** | 2.0 (SQS) |
| **Original Version** | 1.0 (Kinesis) |
| **Modified Date** | April 13, 2026 |
| **Shell** | Git Bash |
| **AWS Region** | us-east-1 |
| **Account ID** | 463183325212 |

---

## Contact/Support

For issues or questions:
1. Review documentation files above
2. Check CloudWatch logs
3. Run validation commands from quick reference
4. Review migration guide for context

---

**Status**: ✓ Lab 2 Ready to Run  
**Last Updated**: April 13, 2026  
**Next Action**: Run `./lab-02.sh` in Git Bash
