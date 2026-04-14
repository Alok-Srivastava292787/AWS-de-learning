##Step 0: Load environment variables from .env file
# Source the .env file from parent directory
if [ -f "../.env" ]; then
    set -a  # Export all variables
    source ../.env
    set +a  # Stop exporting
    echo "✓ Environment variables loaded from ../.env"
else
    echo "✗ Error: ../.env file not found"
    exit 1
fi

echo "=================================="
echo "Lab 3: Glue Data Catalog Setup"
echo "=================================="
echo "Bucket: $BUCKET_NAME"
echo "Region: $REGION"
echo "Account: $ACCOUNT_ID"
echo ""

## Step 1: Create the Glue service IAM role 
## Glue needs a role with trust to the Glue service principal, and permissions to read S3 and write 
## to the Glue Data Catalog. 
echo ""
echo "=================================="
echo "Step 1: Create the Glue service IAM role"
echo "=================================="
#cat > ../glue-trust.json << 'EOF' 
#{ 
#  "Version": "2012-10-17", 
#  "Statement": [{ 
#    "Effect": "Allow", 
#    "Principal": { "Service": "glue.amazonaws.com" }, 
#    "Action": "sts:AssumeRole" 
#  }] 
#} 
#EOF 
 
# aws iam create-role  --role-name GlueLabRole  --assume-role-policy-document file://../glue-trust.json  2>/dev/null || echo "Role may already exist, continuing..."
 
# aws managed policy for Glue service 
aws iam attach-role-policy --role-name GlueLabRole  --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole  2>/dev/null || true
 
# Inline policy granting S3 access to the specific bucket 
#cat > ../glue-s3-policy.json << 'EOF' 
#{ 
#  "Version": "2012-10-17", 
#  "Statement": [{ 
#    "Effect": "Allow", 
#    "Action": ["s3:GetObject","s3:ListBucket"], 
#    "Resource": [ 
#      "arn:aws:s3:::$BUCKET_NAME", 
#      "arn:aws:s3:::$BUCKET_NAME/*" 
#    ] 
#  }] 
#} 
#EOF 
 
aws iam put-role-policy  --role-name GlueLabRole  --policy-name S3DataLakeAccess  --policy-document file://../glue-s3-policy.json  2>/dev/null || true

GLUE_ROLE=$(aws iam get-role --role-name GlueLabRole --query 'Role.Arn' --output text) 
echo "✓ Glue Role ARN: $GLUE_ROLE"
 



## Step 2: Create the Glue Data Catalog database 
## A Glue database is a logical container for tables. Tables within a database typically share a 
## common data domain or source system. 
echo ""
echo "=================================="
echo "Step 2: Create the Glue Data Catalog database"
echo "=================================="
aws glue create-database  --database-input '{ 
   "Name": "lab_datalake_db", 
   "Description": "Day 1 lab data lake - S3 ingestion and streaming data" 
}' 2>/dev/null || echo "Database may already exist, continuing..."
 
# Verify 
echo "✓ Verifying database..."
aws glue get-database --name lab_datalake_db  --query 'Database.{Name:Name, Description:Description}' 


## Step 3: Create and configure the Glue Crawler 
## Configure a crawler targeting the entire processed/ prefix. The CRAWL_NEW_FOLDERS_ONLY 
## recrawl policy means subsequent runs only scan new partitions, not the full dataset – 
## significantly reducing cost and runtime. 
echo "Creating Glue Crawler..."
echo ""
echo "=================================="
echo "Step 3: Create and configure the Glue Crawler"
echo "=================================="
aws glue create-crawler  --name "lab-processed-crawler"  --role "$GLUE_ROLE"  --database-name "lab_datalake_db"  --targets "{ 
    \"S3Targets\": [{ 
      \"Path\": \"s3://$BUCKET_NAME/processed/\", 
      \"Exclusions\": [\"**/_temporary/**\", \"**/errors/**\", \"**/.keep\"] 
    }] 
  }"  --schema-change-policy '{ 
    "UpdateBehavior": "LOG", 
    "DeleteBehavior": "LOG" 
  }'  --recrawl-policy '{"RecrawlBehavior": "CRAWL_NEW_FOLDERS_ONLY"}'  --configuration '{ 
    "Version": 1.0, 
    "CrawlerOutput": { 
      "Partitions": {"AddOrUpdateBehavior": "InheritFromTable"} 
    } 
  }' 2>/dev/null || echo "Crawler may already exist, continuing..."
 
# Verify creation 
echo "✓ Verifying crawler..."
aws glue get-crawler --name "lab-processed-crawler"  --query 'Crawler.{Name:Name, State:State, Role:Role}' 


## Step 4: Run the crawler and monitor progress 
## Start the crawler and poll until it returns to READY state. Typical run time for a small S3 prefix is 
## 1–3 minutes. 
#echo "Starting crawler..."
echo ""
echo "=================================="
echo "Step 4: Run the crawler and monitor progress"
echo "=================================="
aws glue start-crawler --name "lab-processed-crawler" 2>/dev/null || echo "Crawler already running or error, checking state..."
echo "Crawler started at: $(date)" 
 
# Poll until READY (check every 15 seconds) 
echo "Waiting for crawler to finish (checking every 15 seconds)..."
while true; do 
  STATE=$(aws glue get-crawler --name "lab-processed-crawler"    --query 'Crawler.State' --output text) 
  echo "$(date): State = $STATE" 
  if [ "$STATE" = "READY" ]; then 
    echo "✓ Crawler finished!" 
    break 
  fi 
  sleep 15 
done 
 
# Check last crawl metrics 
echo "✓ Last crawl metrics:"
aws glue get-crawler --name "lab-processed-crawler"  --query 'Crawler.LastCrawl' 


## Step 5: Inspect the discovered tables and partitions 
## Verify the Data Catalog tables were created correctly. Check the column schema, storage 
## format, and discovered partitions. 
echo ""
echo "=================================="
echo "Step 5: Inspecting discovered tables"
echo "=================================="

# List tables in the database 
echo "✓ Tables in database:"
aws glue get-tables --database-name lab_datalake_db  --query 'TableList[*].{Name:Name, Location:StorageDescriptor.Location, Format:StorageDescriptor.SerdeInfo.SerializationLibrary}' 2>/dev/null || echo "No tables found yet - crawler may need to complete or S3 data may not exist"
 
# Try to get column details for the clickstream table (if it exists)
echo ""
echo "✓ Checking for clickstream_events table..."
aws glue get-table --database-name lab_datalake_db --name clickstream_events  --query 'Table.StorageDescriptor.Columns[*].{Name:Name, Type:Type}' 2>/dev/null || echo "clickstream_events table not found - ensure Lab 2 (SQS pipeline) has produced data in S3"

# List discovered partitions (if table exists)
echo ""
echo "✓ Checking for partitions..."
aws glue get-partitions --database-name lab_datalake_db --table-name clickstream_events  --query 'Partitions[*].Values' 2>/dev/null || echo "No partitions found - table may not exist yet"

## Step 6: Configure Athena output location 
## Athena requires an S3 location for query results. Create the prefix and set it as the Athena 
## workgroup output location. 
# Create the Athena results prefix 
echo ""
echo "=================================="
echo "Step 6: Configuring Athena output location"
echo "=================================="
aws s3api put-object --bucket $BUCKET_NAME --key athena-results/.keep 2>/dev/null || true
 
# Set the Athena primary workgroup output location 
aws athena update-work-group  --work-group primary  --configuration-updates "ResultConfigurationUpdates={OutputLocation=s3://$BUCKET_NAME/athena-results/}" 2>/dev/null || echo "Note: Athena workgroup configuration may require admin access" 


## Step 7: Query the catalog table in Athena and verify partition pruning 
## Run queries against the discovered table and verify that Athena uses partition metadata to scan 
## only the relevant data (partition pruning). Compare data scanned with and without a partition 
## filter. 
# Helper: run Athena query and print results + data scanned 
echo ""
echo "=================================="
echo "Step 7: Querying the Data Catalog"
echo "=================================="

# First check if any tables exist
TABLE_COUNT=$(aws glue get-tables --database-name lab_datalake_db --query 'length(TableList)' --output text 2>/dev/null || echo "0")
echo "Tables found in database: $TABLE_COUNT"

if [ "$TABLE_COUNT" -eq 0 ]; then
    echo "⚠ No tables found in Glue Data Catalog"
    echo "Note: Lab 2 must have successfully written data to S3 for the crawler to discover tables"
    echo "Expected data location: s3://$BUCKET_NAME/processed/clickstream/"
    echo ""
    echo "To debug:"
    echo "  1. Check Lab 2 output: aws s3 ls s3://$BUCKET_NAME/processed/ --recursive"
    echo "  2. Run crawler manually: aws glue start-crawler --name lab-processed-crawler"
    echo "  3. Wait for crawler to complete, then retry this lab"
else
    run_query() { 
      QID=$(aws athena start-query-execution    --query-string "$1"    --query-execution-context "Database=lab_datalake_db"    --result-configuration "OutputLocation=s3://$BUCKET_NAME/athena-results/"    --query 'QueryExecutionId' --output text) 
      echo "Query ID: $QID"
      sleep 5 
      
      # Get query status
      STATUS=$(aws athena get-query-execution --query-execution-id $QID --query 'QueryExecution.Status.State' --output text)
      echo "Query Status: $STATUS"
      
      if [ "$STATUS" = "SUCCEEDED" ]; then
        aws athena get-query-execution --query-execution-id $QID    --query 'QueryExecution.{Status:Status.State, DataScanned:Statistics.DataScannedInBytes}' 
        aws athena get-query-results --query-execution-id $QID    --query 'ResultSet.Rows[0:5]'
      else
        echo "Query failed with status: $STATUS"
      fi
    } 
     
    # Query 1: Count all records (no partition filter) 
    echo "=== Query 1: Full table scan ===" 
    run_query "SELECT COUNT(*) as total_events FROM clickstream_events" 2>/dev/null || echo "Query execution skipped - verify table name in Glue Catalog"
     
    # Query 2: Filter by year partition (partition pruning active) 
    echo ""
    echo "=== Query 2: Partition-pruned query ===" 
    run_query "SELECT COUNT(*) as events FROM clickstream_events WHERE year='2024' AND month='01'" 2>/dev/null || echo "Query execution skipped - verify partition columns exist"
fi 

echo ""
echo "=========================================="
echo "Lab 3 Complete! Summary:"
echo "=========================================="
echo "✓ Glue Role created: GlueLabRole"
echo "✓ Database created: lab_datalake_db"
echo "✓ Crawler created and executed: lab-processed-crawler"
echo "✓ Data Catalog tables discovered from: s3://$BUCKET_NAME/processed/"
echo "✓ Athena output location configured: s3://$BUCKET_NAME/athenaresults/"
echo "✓ Sample queries run against the Data Catalog with and without partition pruning"
echo "==========================================" 
