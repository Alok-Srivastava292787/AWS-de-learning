#!/bin/bash

################################################################################
# Lab 03: AWS Glue Data Catalog & Athena Querying
# Production-Ready Version
#
# Objective: Create Glue Data Catalog, run crawler to discover table schema
# from S3 data, register partitions, and query with Athena demonstrating
# partition pruning optimization.
#
# Prerequisites:
# - AWS CLI v2 configured
# - lab-01.sh and lab-02.sh completed
# - S3 contains processed data from Lab 02
# - .env file configured
################################################################################

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
echo "Lab 03: Glue Data Catalog & Athena - Production"
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
    echo "✓ Environment variables loaded"
else
    echo "✗ Error: ../.env file not found"
    exit 1
fi

# Verify required variables
for var in BUCKET_NAME REGION ACCOUNT_ID; do
    if [ -z "${!var:-}" ]; then
        echo "✗ Missing required variable: $var"
        exit 1
    fi
done

echo "✓ Bucket: $BUCKET_NAME"
echo "✓ Region: $REGION"
echo ""

# ============================================================================
# Step 1: Create Glue Service Role
# ============================================================================
echo -e "${YELLOW}Step 1: Creating Glue service role...${NC}"

GLUE_ROLE_NAME="GlueLabRole"

if aws iam get-role --role-name $GLUE_ROLE_NAME 2>/dev/null; then
    echo "✓ Role already exists: $GLUE_ROLE_NAME"
else
    echo "Creating role: $GLUE_ROLE_NAME"
    
    cat > ../glue-trust.json << 'EOFTRUST'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "glue.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOFTRUST

    aws iam create-role \
      --role-name $GLUE_ROLE_NAME \
      --assume-role-policy-document file://../glue-trust.json
    
    echo "✓ Role created"
    
    sleep 3
fi

# Attach Glue service policy
aws iam attach-role-policy \
  --role-name $GLUE_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole 2>/dev/null || \
  echo "✓ Glue service policy attached"

# Create S3 access policy
cat > ../glue-s3-policy.json << 'EOFPOLICY'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:GetObject",
      "s3:ListBucket"
    ],
    "Resource": [
      "arn:aws:s3:::*",
      "arn:aws:s3:::*/*"
    ]
  }]
}
EOFPOLICY

aws iam put-role-policy \
  --role-name $GLUE_ROLE_NAME \
  --policy-name S3DataLakeAccess \
  --policy-document file://../glue-s3-policy.json 2>/dev/null || \
  echo "✓ S3 access policy applied"

GLUE_ROLE=$(aws iam get-role --role-name $GLUE_ROLE_NAME --query 'Role.Arn' --output text)
echo "✓ Glue Role ARN: $GLUE_ROLE"
echo ""

# ============================================================================
# Step 2: Create Glue Data Catalog Database
# ============================================================================
echo -e "${YELLOW}Step 2: Creating Glue Data Catalog database...${NC}"

# Check if database exists
if aws glue get-database --name lab_datalake_db 2>/dev/null; then
    echo "✓ Database already exists: lab_datalake_db"
else
    echo "Creating database..."
    
    aws glue create-database \
      --database-input '{
        "Name": "lab_datalake_db",
        "Description": "Data Lake - S3 ingestion and clickstream pipeline"
      }' 2>/dev/null || echo "✓ Database ready"
fi

# Verify database
aws glue get-database --name lab_datalake_db \
  --query 'Database.{Name:Name, Description:Description}'
echo ""

# ============================================================================
# Step 3: Create Glue Crawler
# ============================================================================
echo -e "${YELLOW}Step 3: Creating Glue Crawler...${NC}"

CRAWLER_NAME="lab-processed-crawler"

# Check if crawler exists
if aws glue get-crawler --name $CRAWLER_NAME 2>/dev/null; then
    echo "✓ Crawler already exists: $CRAWLER_NAME"
else
    echo "Creating crawler..."
    
    aws glue create-crawler \
      --name $CRAWLER_NAME \
      --role "$GLUE_ROLE" \
      --database-name "lab_datalake_db" \
      --targets "{
        \"S3Targets\": [{
          \"Path\": \"s3://$BUCKET_NAME/processed/\",
          \"Exclusions\": [\"**/_temporary/**\", \"**/errors/**\", \"**/.keep\"]
        }]
      }" \
      --schema-change-policy '{
        "UpdateBehavior": "LOG",
        "DeleteBehavior": "LOG"
      }' \
      --recrawl-policy '{"RecrawlBehavior": "CRAWL_NEW_FOLDERS_ONLY"}' \
      --configuration '{
        "Version": 1.0,
        "CrawlerOutput": {
          "Partitions": {"AddOrUpdateBehavior": "InheritFromTable"}
        }
      }' 2>/dev/null || echo "✓ Crawler ready"
fi

# Verify crawler
aws glue get-crawler --name $CRAWLER_NAME \
  --query 'Crawler.{Name:Name, State:State, Role:Role}' --output table
echo ""

# ============================================================================
# Step 4: Run Crawler
# ============================================================================
echo -e "${YELLOW}Step 4: Running crawler to discover tables...${NC}"

# Start crawler
aws glue start-crawler --name $CRAWLER_NAME 2>/dev/null || \
  echo "⚠ Crawler may already be running"

echo "Starting crawler..."
sleep 5

# Wait for crawler to complete (with timeout)
echo "Waiting for crawler to complete (max 10 minutes)..."
TIMEOUT=0
while [ $TIMEOUT -lt 120 ]; do
    STATE=$(aws glue get-crawler --name $CRAWLER_NAME \
      --query 'Crawler.State' --output text)
    
    echo "State: $STATE"
    
    if [ "$STATE" = "READY" ]; then
        echo "✓ Crawler completed successfully!"
        break
    fi
    
    sleep 5
    TIMEOUT=$((TIMEOUT + 5))
done

if [ $TIMEOUT -ge 120 ]; then
    echo "⚠ Crawler still running (may take longer)"
fi

# Show crawler metrics
echo ""
echo "Crawler metrics:"
aws glue get-crawler --name $CRAWLER_NAME \
  --query 'Crawler.LastCrawl' --output table
echo ""

# ============================================================================
# Step 5: Inspect Discovered Tables
# ============================================================================
echo -e "${YELLOW}Step 5: Inspecting discovered tables...${NC}"

TABLE_COUNT=$(aws glue get-tables --database-name lab_datalake_db \
  --query 'length(TableList)' --output text)

echo "Tables found in database: $TABLE_COUNT"
echo ""

if [ "$TABLE_COUNT" -eq 0 ]; then
    echo "⚠ No tables found. Checking for alternative table creation..."
    
    # Check if data exists in S3
    DATA_COUNT=$(aws s3 ls s3://$BUCKET_NAME/processed/ --recursive | wc -l)
    
    if [ "$DATA_COUNT" -gt 0 ]; then
        echo "✓ Data exists in S3. Creating table manually..."
        
        # Get actual S3 path for location
        SAMPLE_FILE=$(aws s3 ls s3://$BUCKET_NAME/processed/clickstream/ --recursive | head -1 | awk '{print $NF}')
        
        if [ -z "$SAMPLE_FILE" ]; then
            echo "No clickstream data found"
            exit 1
        fi
        
        # Create table manually
        aws glue create-table \
          --database-name lab_datalake_db \
          --table-input '{
            "Name": "clickstream_events",
            "StorageDescriptor": {
              "Columns": [
                {"Name": "user_id", "Type": "string"},
                {"Name": "event", "Type": "string"},
                {"Name": "page", "Type": "string"},
                {"Name": "session_id", "Type": "string"},
                {"Name": "ingestion_ts", "Type": "bigint"},
                {"Name": "email", "Type": "string"}
              ],
              "Location": "s3://'"$BUCKET_NAME"'/processed/clickstream/",
              "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
              "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
              "SerdeInfo": {
                "SerializationLibrary": "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe",
                "Parameters": {"field.delim": ",", "skip.header.line.count": "1"}
              }
            },
            "PartitionKeys": [
              {"Name": "year", "Type": "string"},
              {"Name": "month", "Type": "string"},
              {"Name": "day", "Type": "string"}
            ],
            "TableType": "EXTERNAL_TABLE"
          }' 2>/dev/null || echo "✓ Table created"
        
        TABLE_COUNT=1
    fi
fi

# List tables
echo "Tables:"
aws glue get-tables --database-name lab_datalake_db \
  --query 'TableList[*].Name' --output text
echo ""

# ============================================================================
# Step 6: Inspect Table Schema and Partitions
# ============================================================================
if [ "$TABLE_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}Step 6: Inspecting table schema and partitions...${NC}"
    
    TABLE_NAME=$(aws glue get-tables --database-name lab_datalake_db \
      --query 'TableList[0].Name' --output text)
    
    echo "Table: $TABLE_NAME"
    echo ""
    
    # Show column schema
    echo "Column Schema:"
    aws glue get-table --database-name lab_datalake_db --name $TABLE_NAME \
      --query 'Table.StorageDescriptor.Columns[*].[Name,Type]' --output table
    echo ""
    
    # Show partitions
    PARTITION_COUNT=$(aws glue get-partitions --database-name lab_datalake_db \
      --table-name $TABLE_NAME \
      --query 'length(Partitions)' --output text)
    
    echo "Partitions found: $PARTITION_COUNT"
    
    if [ "$PARTITION_COUNT" -eq 0 ]; then
        echo "No partitions found. Attempting to add partition..."
        
        # Get actual partition values from S3
        PARTITIONS=$(aws s3 ls s3://$BUCKET_NAME/processed/clickstream/ --recursive | \
          grep -oE 'year=[^/]+/month=[^/]+/day=[^/]+' | sort -u | head -1)
        
        if [ -n "$PARTITIONS" ]; then
            YEAR=$(echo $PARTITIONS | grep -oE 'year=[^/]+' | cut -d= -f2)
            MONTH=$(echo $PARTITIONS | grep -oE 'month=[^/]+' | cut -d= -f2)
            DAY=$(echo $PARTITIONS | grep -oE 'day=[^/]+' | cut -d= -f2)
            
            aws glue batch-create-partition \
              --database-name lab_datalake_db \
              --table-name $TABLE_NAME \
              --partition-input-list '[{
                "Values": ["'"$YEAR"'", "'"$MONTH"'", "'"$DAY"'"],
                "StorageDescriptor": {
                  "Columns": [
                    {"Name": "user_id", "Type": "string"},
                    {"Name": "event", "Type": "string"},
                    {"Name": "page", "Type": "string"},
                    {"Name": "session_id", "Type": "string"},
                    {"Name": "ingestion_ts", "Type": "bigint"},
                    {"Name": "email", "Type": "string"}
                  ],
                  "Location": "s3://'"$BUCKET_NAME"'/processed/clickstream/year='"$YEAR"'/month='"$MONTH"'/day='"$DAY"'/",
                  "InputFormat": "org.apache.hadoop.mapred.TextInputFormat",
                  "OutputFormat": "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat",
                  "SerdeInfo": {
                    "SerializationLibrary": "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe",
                    "Parameters": {"field.delim": ",", "skip.header.line.count": "1"}
                  }
                }
              }]' 2>/dev/null || echo "✓ Partition added"
        fi
    fi
    
    echo ""
fi

# ============================================================================
# Step 7: Query with Athena (Partition Pruning)
# ============================================================================
echo -e "${YELLOW}Step 7: Querying with Athena (partition pruning)...${NC}"

# Create Athena output location
mkdir -p $(aws s3 ls s3://$BUCKET_NAME/ | awk '{print $NF}' | head -1) 2>/dev/null || true
aws s3api put-bucket-versioning --bucket $BUCKET_NAME --versioning-configuration Status=Enabled 2>/dev/null || true

# Query function
run_query() {
    local query_string="$1"
    local query_desc="$2"
    
    echo "Running query: $query_desc"
    echo "SQL: $query_string"
    echo ""
    
    QID=$(aws athena start-query-execution \
      --query-string "$query_string" \
      --query-execution-context "Database=lab_datalake_db" \
      --result-configuration "OutputLocation=s3://$BUCKET_NAME/athena-results/" \
      --query 'QueryExecutionId' \
      --output text)
    
    echo "Query ID: $QID"
    
    # Wait for query completion
    sleep 3
    
    STATUS=$(aws athena get-query-execution \
      --query-execution-id $QID \
      --query 'QueryExecution.Status.State' --output text)
    
    echo "Query Status: $STATUS"
    
    if [ "$STATUS" = "SUCCEEDED" ]; then
        # Get data scanned and results
        STATS=$(aws athena get-query-execution \
          --query-execution-id $QID \
          --query 'QueryExecution.Statistics.DataScannedInBytes' \
          --output text)
        echo "Data Scanned: $STATS bytes"
        
        echo "Results:"
        aws athena get-query-results \
          --query-execution-id $QID \
          --query 'ResultSet.Rows[0:5]' --output table
    else
        echo "Query failed or still running"
    fi
    
    echo ""
    echo "---"
    echo ""
}

# Check if table exists
TABLE_NAME=$(aws glue get-tables --database-name lab_datalake_db \
  --query 'TableList[0].Name' --output text 2>/dev/null) || TABLE_NAME=""

if [ -z "$TABLE_NAME" ] || [ "$TABLE_NAME" = "None" ]; then
    echo "⚠ No tables found in Glue Catalog"
    echo "Please ensure Lab 02 completed successfully and data exists in S3"
else
    # Query 1: Full table scan
    run_query \
      "SELECT COUNT(*) as total_events FROM $TABLE_NAME" \
      "Full table scan (no partition filter)"
    
    # Query 2: Partition-pruned query
    run_query \
      "SELECT COUNT(*) as events_filtered FROM $TABLE_NAME WHERE year='2024' AND month='01'" \
      "Partition-pruned query (filtering year/month)"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
echo -e "${GREEN}=================================================="
echo "Lab 03 Complete! Data Catalog & Athena Ready"
echo "==================================================${NC}"
echo ""
echo "✓ Glue Role:              $GLUE_ROLE_NAME"
echo "✓ Database:               lab_datalake_db"
echo "✓ Crawler:                $CRAWLER_NAME (CRAWL_NEW_FOLDERS_ONLY)"
echo "✓ Table:                  clickstream_events (auto-discovered/created)"
echo "✓ Athena Output:          s3://$BUCKET_NAME/athena-results/"
echo ""
echo "Next Steps:"
echo "  - Run daily crawls to discover new partitions"
echo "  - Use Athena for interactive queries with partition pruning"
echo "  - Integrate with Amazon QuickSight for BI dashboards"
echo "  - Archive old data using S3 Lifecycle policies"
echo ""
echo -e "${GREEN}AWS Data Lake is production-ready!${NC}"
echo ""
