#!/usr/bin/env bash
#------------------
# Equivalent of “provision Redshift Serverless workgroup” in a lakehouse world:

# -create/query environment (Athena workgroup)
# -create catalog container (Glue database)
# -create discovery pipeline (Glue crawler)
# -Athena workgroups and Glue databases/crawlers are all directly supported via the AWS CLI.
#-------
set -euo pipefail
source "${1:-./00_env.sh}"

# 1) Ensure S3 prefixes exist (S3 is prefix-based; zero-byte "folder markers" are optional)
aws s3api put-object \
  --bucket "$LAKE_BUCKET" \
  --key "clickstream/raw/.keep" \
  --region "$AWS_REGION"

aws s3api put-object \
  --bucket "$LAKE_BUCKET" \
  --key "clickstream/silver/.keep" \
  --region "$AWS_REGION"

aws s3api put-object \
  --bucket "$LAKE_BUCKET" \
  --key "clickstream/gold/.keep" \
  --region "$AWS_REGION"

aws s3api put-object \
  --bucket "$LAKE_BUCKET" \
  --key "scripts/.keep" \
  --region "$AWS_REGION"

aws s3api put-object \
  --bucket "$LAKE_BUCKET" \
  --key "athena-results/.keep" \
  --region "$AWS_REGION"

# 2) Athena workgroup (equivalent query workspace)
if aws athena get-work-group --work-group "$ATHENA_WORKGROUP" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Athena workgroup $ATHENA_WORKGROUP already exists."
else
  aws athena create-work-group \
    --name "$ATHENA_WORKGROUP" \
    --description "Clickstream analytical workgroup" \
    --configuration "ResultConfiguration={OutputLocation=${ATHENA_RESULTS_S3}},EnforceWorkGroupConfiguration=true" \
    --region "$AWS_REGION"
fi

# 3) Glue database
if aws glue get-database --name "$GLUE_DB" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Glue database $GLUE_DB already exists."
else
  aws glue create-database \
    --database-input "{\"Name\":\"$GLUE_DB\",\"Description\":\"Clickstream Data Catalog database\"}" \
    --region "$AWS_REGION"
fi

# 4) Glue crawler targeting the Gold layer
if aws glue get-crawler --name "$GLUE_CRAWLER" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Crawler $GLUE_CRAWLER already exists; updating target to GOLD_PREFIX."
  aws glue update-crawler \
    --name "$GLUE_CRAWLER" \
    --role "$GLUE_ROLE" \
    --database-name "$GLUE_DB" \
    --targets "{\"S3Targets\":[{\"Path\":\"${GOLD_PREFIX}\"}]}" \
    --recrawl-policy '{"RecrawlBehavior":"CRAWL_EVERYTHING"}' \
    --region "$AWS_REGION"
else
  aws glue create-crawler \
    --name "$GLUE_CRAWLER" \
    --role "$GLUE_ROLE" \
    --database-name "$GLUE_DB" \
    --targets "{\"S3Targets\":[{\"Path\":\"${GOLD_PREFIX}\"}]}" \
    --schema-change-policy '{"UpdateBehavior":"UPDATE_IN_DATABASE","DeleteBehavior":"LOG"}' \
    --recrawl-policy '{"RecrawlBehavior":"CRAWL_EVERYTHING"}' \
    --region "$AWS_REGION"
fi

echo "Provisioning done."
