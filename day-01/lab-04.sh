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
echo "✓ Lambda Role:    $LAMBDA_ROLE_NAME"

##Step 1: Create the SNS topic and subscribe your email 
##The state machine sends pipeline success/failure alerts via SNS. Create the topic and subscribe 
##your email so you can verify notifications end-to-end. 

# Configuration
BUCKET_NAME="my-datalake-lab-alok"
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID="463183325212"

echo -e ${YELLOW}"=================================================="
echo -e "Step 1: Create the SNS topic and subscribe your email"
echo -e "==================================================${NC}"
echo ""
# Create SNS topic 
if (aws sns get-topic-attributes --topic-arn "arn:aws:sns:$AWS_REGION:$AWS_ACCOUNT_ID:ingestion-alerts" --query 'TopicArn' --output text) 2>/dev/null; then
    echo -e ${GREEN}"✓ Topic already exists $$"${NC}
else
    echo "Creating topic: ingestion-alerts"
    SNS_ARN=$(aws sns create-topic --name ingestion-alerts --region $AWS_REGION --query 'TopicArn' --output text) 
fi
 
# Subscribe your email (replace with your actual email) 
#aws sns subscribe  --topic-arn $SNS_ARN  --protocol email  --notification-endpoint "292787@ust.com" 
 
echo -e ${YELLOW}"Check your email and confirm the subscription before continuing."${NC} 
#echo "SNS_ARN=$SNS_ARN"

## Step 2: Create the IAM role for Step Functions 
## Step Functions needs permissions to invoke Lambda, start Glue crawlers, query Glue state, 
## publish to SNS, and start its own executions (for nested state machines). 
echo -e ${YELLOW}"=================================================="
echo -e "Step 2: Create the IAM role for Step Functions"
echo -e "==================================================${NC}"
echo ""
# Check if role already exists
if (aws iam get-role --role-name StepFunctionsIngestionRole --query 'Role.Arn') 2>/dev/null; then
    echo -e ${GREEN}"✓ Role already exists: StepFunctionsIngestionRole"${NC}
else
    echo "Creating  role..."
    cat > ../sfn-trust.json << 'EOF'
{ 
  "Version": "2012-10-17", 
  "Statement": [{ 
    "Effect": "Allow", 
    "Principal": { "Service": "states.amazonaws.com" }, 
    "Action": "sts:AssumeRole" 
  }] 
}
EOF

    aws iam create-role  --role-name StepFunctionsIngestionRole  --assume-role-policy-document file://../sfn-trust.json 
fi


# Inline policy with all required permissions 
#checking if it already exists to avoid overwriting any manual changes if the script is re-run. In a production setup, you would typically manage this with CloudFormation or Terraform for idempotency and version control.
if (aws iam get-role --role-name StepFunctionsIngestionRole  --query 'Role.Arn' --output text) 2>/dev/null; then
    echo -e ${GREEN}"✓ Role-policy already exists: $$"${NC}
else
    echo "Creating  role-policy..."
cat > ../sfn-policy.json << 'POLICY_EOF'
{ 
  "Version": "2012-10-17", 
  "Statement": [ 
    { 
      "Effect": "Allow", 
      "Action": ["lambda:InvokeFunction"], 
      "Resource": "arn:aws:lambda:*:*:function:*" 
    }, 
    { 
      "Effect": "Allow", 
      "Action": ["glue:StartCrawler","glue:GetCrawler","glue:StopCrawler"], 
      "Resource": "arn:aws:glue:*:*:crawler/*" 
    }, 
    { 
      "Effect": "Allow", 
      "Action": ["sns:Publish"], 
      "Resource": "PLACEHOLDER_SNS_ARN" 
    }, 
    { 
      "Effect": "Allow", 
      "Action": ["s3:GetObject","s3:HeadObject","s3:ListBucket"], 
      "Resource": ["arn:aws:s3:::PLACEHOLDER_BUCKET_NAME","arn:aws:s3:::PLACEHOLDER_BUCKET_NAME/*"] 
    }, 
    { 
      "Effect": "Allow", 
      "Action": ["logs:CreateLogGroup","logs:CreateLogDelivery","logs:PutLogEvents"], 
      "Resource": "arn:aws:logs:*:*:*" 
    } 
  ] 
} 
POLICY_EOF

# Replace placeholders with actual values
sed -i "s|PLACEHOLDER_SNS_ARN|$SNS_ARN|g" ../sfn-policy.json
sed -i "s|PLACEHOLDER_BUCKET_NAME|$BUCKET_NAME|g" ../sfn-policy.json
 
aws iam put-role-policy  --role-name StepFunctionsIngestionRole  --policy-name SFNIngestionPolicy  --policy-document file://../sfn-policy.json 

SFN_ROLE=$(aws iam get-role --role-name StepFunctionsIngestionRole  --query 'Role.Arn' --output text) 
echo "Step Functions Role ARN: $SFN_ROLE" 
fi

## Step 3: Create the input validation Lambda function 
## This function checks whether the S3 object specified in the pipeline input actually exists. It 
## returns {valid: true/false} which the state machine uses for branching. 
echo -e ${YELLOW}"=================================================="
echo -e "Step 3: Create the input validation Lambda function"
echo -e "==================================================${NC}"
echo ""

if (aws lambda get-function --function-name pipeline-validate-input) &>/dev/null; then
    echo -e ${GREEN}"✓ Function already exists: pipeline-validate-input"${NC}
else
    echo "Creating pipeline-validate-input function..."
cat > ../validate_input.py << 'inputEOF' 
import boto3, json, logging 
logger = logging.getLogger() 
logger.setLevel(logging.INFO) 
 
s3 = boto3.client('s3') 
 
def lambda_handler(event, context): 
    bucket = event.get('bucket') 
    key    = event.get('key') 
    if not bucket or not key: 
        raise ValueError("Missing 'bucket' or 'key' in input") 
    try: 
        s3.head_object(Bucket=bucket, Key=key) 
        logger.info(f"Validated: s3://{bucket}/{key}") 
        return {**event, 'valid': True, 'message': f"Object exists: {key}"} 
    except s3.exceptions.ClientError as e: 
        if e.response['Error']['Code'] == '404': 
            logger.warning(f"Object not found: s3://{bucket}/{key}") 
            raise Exception(f"ValidationError: Object not found: 
s3://{bucket}/{key}") 
        raise 
inputEOF
 
#cd .. && zip validate_input.zip validate_input.py 
#cd .. && tar -czf validate_input.tar.gz validate_input.py
 
# Check if function exists
aws lambda create-function  --function-name pipeline-validate-input  --runtime python3.12  --role $LAMBDA_ROLE_ARN  --handler validate_input.lambda_handler  --zip-file fileb://../validate_input.zip  --timeout 30 
 
VALIDATE_ARN=$(aws lambda get-function --function-name pipeline-validate-input  --query 'Configuration.FunctionArn' --output text) 
echo "Validate Lambda ARN: $VALIDATE_ARN" 
fi


## Step 4: Define and deploy the Step Functions state machine (ASL) 
## The state machine implements the full pipeline: Validate → StartCrawler → Poll crawler state → 
## (Success: NotifySuccess) / (Failure: NotifyFailure). It includes retry logic on transient AWS 
## service errors. 
echo -e ${YELLOW}"=================================================="
echo -e "Step 4: Define and deploy the Step Functions state machine"
echo -e "==================================================${NC}"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) 

# Check if Step Functions state machine exists

STATE_MACHINE_NAME="IngestionPipeline"
SFN_ARN=$(aws stepfunctions list-state-machines --query "stateMachines[?name=='$STATE_MACHINE_NAME'].stateMachineArn" --output text)
if [ "$SFN_ARN" ]; then
  echo -e ${GREEN}"State machine already exists: $SFN_ARN"${NC}
else
  echo "Creating state machine..."

cat > ../pipeline_asl.json << 'EOF' 
{ 
  "Comment": "Ingestion Pipeline: validate input, run Glue crawler, notify result", 
  "StartAt": "ValidateInput", 
  "States": { 
    "ValidateInput": { 
      "Type": "Task", 
      "Resource": "arn:aws:states:::lambda:invoke", 
      "Parameters": { 
        "FunctionName": "$VALIDATE_ARN", 
        "Payload.$": "$" 
      }, 
      "ResultSelector": { "body.$": "States.StringToJson(States.Format('{}', States.JsonToString($.Payload)))" }, 
      "ResultPath": "$.validation", 
      "Retry": [{ 
        "ErrorEquals": ["Lambda.ServiceException","Lambda.AWSLambdaException"], 
        "IntervalSeconds": 5, "MaxAttempts": 3, "BackoffRate": 2 
      }], 
      "Catch": [{ 
        "ErrorEquals": ["States.ALL"], 
        "ResultPath": "$.error", 
        "Next": "NotifyFailure" 
      }], 
      "Next": "StartGlueCrawler" 
    }, 
    "StartGlueCrawler": { 
      "Type": "Task", 
      "Resource": "arn:aws:states:::aws-sdk:glue:startCrawler", 
      "Parameters": { "Name": "lab-processed-crawler" }, 
      "ResultPath": null, 
      "Catch": [{ 
        "ErrorEquals": ["Glue.CrawlerRunningException"], 
        "ResultPath": "$.error", 
        "Next": "WaitForCrawler" 
      },{ 
        "ErrorEquals": ["States.ALL"], 
        "ResultPath": "$.error", 
        "Next": "NotifyFailure" 
      }], 
      "Next": "WaitForCrawler" 
    }, 
    "WaitForCrawler": { 
      "Type": "Wait", 
      "Seconds": 20, 
      "Next": "CheckCrawlerStatus" 
    }, 
    "CheckCrawlerStatus": { 
      "Type": "Task", 
      "Resource": "arn:aws:states:::aws-sdk:glue:getCrawler", 
      "Parameters": { "Name": "lab-processed-crawler" }, 
      "ResultPath": "$.crawlerResult", 
      "Next": "IsCrawlerDone" 
    }, 
    "IsCrawlerDone": { 
      "Type": "Choice", 
      "Choices": [
	     { "Variable": "$.crawlerResult.Crawler.State", "StringEquals": "READY", "Next": "CheckLastCrawlStatus" }, 
        { "Variable": "$.crawlerResult.Crawler.State", "StringEquals": "STOPPING", "Next": "WaitForCrawler" } 
      ], 
      "Default": "WaitForCrawler" 
    }, 
    "CheckLastCrawlStatus": { 
      "Type": "Choice", 
      "Choices": [{ 
        "Variable": "$.crawlerResult.Crawler.LastCrawl.Status", 
        "StringEquals": "SUCCEEDED", 
        "Next": "NotifySuccess" 
      }], 
      "Default": "NotifyFailure" 
    }, 
    "NotifySuccess": { 
      "Type": "Task", 
      "Resource": "arn:aws:states:::sns:publish", 
      "Parameters": { 
        "TopicArn": "$SNS_ARN", 
        "Subject": " Ingestion Pipeline Succeeded", 
        "Message.$": "States.Format('Pipeline completed for bucket={} key={}. Crawler finished successfully.', $.bucket, $.key)" 
      }, 
      "End": true 
    }, 
    "NotifyFailure": { 
      "Type": "Task", 
      "Resource": "arn:aws:states:::sns:publish", 
      "Parameters": { 
        "TopicArn": "$SNS_ARN", 
        "Subject": " Ingestion Pipeline FAILED", 
        "Message.$": "States.Format('Pipeline FAILED for bucket={} key={}. Error: {}', $.bucket, $.key, States.JsonToString($.error))" 
      }, 
      "End": true 
    } 
  } 
}
EOF
 
# Deploy the state machine 
SFN_ARN=$( aws stepfunctions create-state-machine  --name IngestionPipeline  --definition file://../pipeline_asl.json  --role-arn arn:aws:iam::463183325212:role/StepFunctionsIngestionRole  --query 'stateMachineArn' --output text) 
 
echo "State Machine ARN: $SFN_ARN" 
fi 

## Step 5: Test the happy path (valid S3 object) 
## Start a manual execution with a known-good S3 object. Monitor execution progress and verify 
## the success notification is sent. 
# Start an execution with a valid S3 key 
echo -e ${YELLOW}"=================================================="
echo -e "Step 5: Test the happy path (valid S3 object)"
echo -e "==================================================${NC}"
echo ""

EXEC_ARN=$(aws stepfunctions start-execution  --state-machine-arn $SFN_ARN  --name "test-happy-path-$(date +%s)"  --input "{ 
    \"bucket\": \"$BUCKET_NAME\", \"key\": \"raw/source=csv/year=2024/month=01/sample_events.csv\" 
  }"  --query 'executionArn' --output text) 
 
echo "Execution ARN: $EXEC_ARN" 
 
# Poll for completion 
while true; do 
  STATUS=$(aws stepfunctions describe-execution    --execution-arn $EXEC_ARN    --query 'status' --output text) 
  echo "$(date): Status = $STATUS" 
  [ "$STATUS" = "RUNNING" ] || break 
  sleep 10 
done 
 
# Get execution history summary 
aws stepfunctions get-execution-history  --execution-arn $EXEC_ARN  --query 'events[*].{Type:type, Timestamp:timestamp}'  --output table 


## Step 6: Test the failure path (non-existent S3 object) 
## Start an execution with an invalid S3 key. The ValidateInput Lambda throws an exception, the 
## Catch block routes to NotifyFailure, and a failure SNS notification is sent. 
echo -e ${YELLOW}"=================================================="
echo -e "Step 6: Test the failure path (non-existent S3 object)"
echo -e "==================================================${NC}"
echo ""

EXEC_ARN_FAIL=$(aws stepfunctions start-execution  --state-machine-arn $SFN_ARN  --name "test-failure-path-$(date +%s)"  --input "{ 
    \"bucket\": \"$BUCKET_NAME\", 
    \"key\": \"raw/non-existent-file-that-does-not-exist.csv\" 
  }"  --query 'executionArn' --output text) 
  echo -e ${RED}"Failure test Execution ARN: $EXEC_ARN_FAIL"{NC} 
 
# Poll for completion (should be fast - Lambda fails immediately) 
while true; do 
  STATUS=$(aws stepfunctions describe-execution    --execution-arn $EXEC_ARN_FAIL    --query 'status' --output text) 
  echo "$(date): Status = $STATUS" 
  [ "$STATUS" = "RUNNING" ] || break 
  sleep 5 
done 
 
# Show the error that was caught 
aws stepfunctions describe-execution  --execution-arn $EXEC_ARN_FAIL  --query 'output' 

## Step 7: Create the EventBridge scheduled rule for production 
## Schedule the pipeline to run automatically every night at 2:00 AM UTC. The EventBridge rule 
## invokes Step Functions with a fixed input payload. 
echo -e ${YELLOW}"=================================================="
echo -e "Step 7: Create the EventBridge scheduled rule for production"
echo -e "==================================================${NC}"
echo ""
# Create IAM role for EventBridge to invoke Step Functions 
  
if aws iam get-role --role-name EventBridgeSFNRole --query Arn.role --output text 2>/dev/null; then
    echo -e ${GREEN}"✓ Role already exists: EventBridgeSFNRole $$"${NC}
else
    echo "Creating  EventBridgeSFNRole role..."

cat > ../eb-trust.json << 'EOF'
{ 
  "Version": "2012-10-17", 
  "Statement": [{ 
    "Effect": "Allow", 
    "Principal": { "Service": "events.amazonaws.com" }, 
    "Action": "sts:AssumeRole" 
  }] 
}
EOF

aws iam create-role --role-name EventBridgeSFNRole   --assume-role-policy-document file://../eb-trust.json 
fi

if (aws iam get-role --role-name EventBridgeSFNRole  --query 'Role.Arn' --output text) 2>/dev/null; then
    echo -e ${GREEN}"✓ Role-policy already exists: $$"${NC}
else
    echo "Creating  role-policy..."
aws iam put-role-policy --role-name EventBridgeSFNRole  --policy-name InvokeSFN  --policy-document "{ 
    \"Version\": \"2012-10-17\", 
    \"Statement\": [{ 
      \"Effect\": \"Allow\", 
      \"Action\": \"states:StartExecution\", 
      \"Resource\": \"$SFN_ARN\" 
    }] 
  }"
fi
  EB_ROLE=$(aws iam get-role --role-name EventBridgeSFNRole --query 'Role.Arn' --output text)
# Create the daily schedule rule (2 AM UTC) 

if (aws events get-rule  --name "daily-ingestion-pipeline" 2>/dev/null); then
    echo -e ${GREEN}"✓ daily-ingestion-pipeline: $$"${NC}
else
    echo "Creating  daily-ingestion-pipeline..."
aws events put-rule  --name "daily-ingestion-pipeline"  --schedule-expression "cron(0 2 * * ? *)"  --region us-east-1 --state ENABLED  --description "Trigger nightly data ingestion pipeline at 2AM UTC" 
echo "EBROLE: $EB_ROLE" 
# Add Step Functions as the target 

aws events put-targets  --rule "daily-ingestion-pipeline"  --targets file://targets.rendered.json --region us-east-1
#     \"Input\": \"{\"bucket\": \"$BUCKET_NAME\", \"key\": \"raw/source=csv/year=2024/month=01/sample_events.csv\"}\"
 
echo "Scheduled rule created: daily-ingestion-pipeline" 
fi
echo -e${BLUE}"Next run: tomorrow at 02:00 UTC" ${NC}


## Step 8: Verify end-to-end pipeline via CloudWatch dashboard 
echo -e ${YELLOW}"=================================================="
echo -e "Step 8: Verify end-to-end pipeline via CloudWatch dashboard"
echo -e "==================================================${NC}"
echo ""
## Create a simple CloudWatch dashboard to monitor the pipeline's key health metrics in one place. 

if (aws cloudwatch get-dashboard --dashboard-name "IngestionPipelineDashboard" 2>/dev/null); then
    echo -e ${GREEN}"✓ dashboard IngestionPipelineDashboard already exists: $$"${NC}
else
    echo "Creating  dashboard IngestionPipelineDashboard..."

 aws cloudwatch put-dashboard --dashboard-name "IngestionPipelineDashboard" --dashboard-body file://put_target_a.json --region us-east-1

fi

aws cloudwatch get-dashboard --dashboard-name IngestionPipelineDashboard --region us-east-1

echo "Dashboard created. View at:" 
echo "https://console.aws.amazon.com/cloudwatch/home?region=us-east1#dashboards:name=IngestionPipelineDashboard" 
