
#!/usr/bin/env bash
set -euo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")}"

# ---------- Existing S3 bucket for the lakehouse ----------
export LAKE_BUCKET="${LAKE_BUCKET:-shopstream-datalake-463183325212-us-east-1-an}"

# ---------- Local input CSV (your lab file on disk) ----------
export LOCAL_CLICKSTREAM_CSV="${LOCAL_CLICKSTREAM_CSV:-clickstream.csv}"

# ---------- S3 prefixes ----------
export RAW_PREFIX="s3://${LAKE_BUCKET}/clickstream/raw/"
export SILVER_PREFIX="s3://${LAKE_BUCKET}/clickstream/silver/"
export GOLD_PREFIX="s3://${LAKE_BUCKET}/clickstream/gold/"
export SCRIPT_PREFIX="s3://${LAKE_BUCKET}/scripts/"
export ATHENA_RESULTS_S3="s3://${LAKE_BUCKET}/athena-results/"

# ---------- Athena / Glue ----------
export ATHENA_WORKGROUP="${ATHENA_WORKGROUP:-clickstream-wg}"
export GLUE_DB="${GLUE_DB:-database shopstream_dw}"
export GLUE_CRAWLER="${GLUE_CRAWLER:-clickstream-gold-crawler}"
export GLUE_JOB="${GLUE_JOB:-clickstream-etl-job}"
export GLUE_ROLE="${GLUE_ROLE:-GlueLabRole}"

# ---------- DynamoDB ----------
export PRODUCTS_TABLE="${PRODUCTS_TABLE:-products}"
export PRODUCTS_TABLE="${PRODUCTS_TABLE:-products}"
export PRODUCTS_CSV="${PRODUCTS_CSV:-products.csv}"
export DDB_HASH_KEY="${DDB_HASH_KEY:-product_id}"
export DDB_NUMBER_FIELDS="${DDB_NUMBER_FIELDS:-price}"

# ---------- Lambda / API Gateway ----------
export LAMBDA_NAME="${LAMBDA_NAME:-product-lookup-api}"
export API_NAME="${API_NAME:-product-lookup-api}"
export API_STAGE="${API_STAGE:-dev}"
export LAMBDA_RUNTIME="${LAMBDA_RUNTIME:-python3.12}"

# ---------- Build dir ----------
export BUILD_DIR="${BUILD_DIR:-$(pwd)/.build-clickstream}"
mkdir -p "$BUILD_DIR"

echo "AWS_REGION=$AWS_REGION"
echo "AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID"
echo "LAKE_BUCKET=$LAKE_BUCKET"
echo "RAW_PREFIX=$RAW_PREFIX"
echo "GOLD_PREFIX=$GOLD_PREFIX"
echo "GLUE_DB=$GLUE_DB"
echo "ATHENA_WORKGROUP=$ATHENA_WORKGROUP"
echo "GLUE_JOB=$GLUE_JOB"
