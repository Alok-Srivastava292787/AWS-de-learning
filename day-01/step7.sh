STATE_MACHINE_NAME="IngestionPipeline"
SFN_ARN=$(aws stepfunctions list-state-machines --query "stateMachines[?name=='$STATE_MACHINE_NAME'].stateMachineArn" --output text)
echo "State Machine ARN: $SFN_ARN"
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

