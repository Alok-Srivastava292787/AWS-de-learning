#!/usr/bin/env bash
#--------------------------------------
# Equivalent of both:
#  -“Run BI Analytical Queries in Redshift”
#  -“Run Ad-Hoc E-Commerce Queries on Gold Layer via Athena”
# -Here we:
#  -crawl/catalog the Gold Parquet output into Glue Data Catalog, and
#  -run Athena SQL queries against the cataloged table.
#  -start-crawler runs the crawler immediately; Athena start-query-execution runs the SQL asynchronously and requires an S3 results location if none is enforced by the workgroup.
#--------------------------------------
#set -euo pipefail
source "${1:-./00_env.sh}"

# 1) Start crawler
aws glue start-crawler --name "$GLUE_CRAWLER" --region "$AWS_REGION" || true

# 2) Wait for crawler to become READY again
echo "Waiting for crawler to finish..."
for i in $(seq 1 60); do
  STATE=$(aws glue get-crawler --name "$GLUE_CRAWLER" --region "$AWS_REGION" --query 'Crawler.State' --output text)
  echo "Crawler state: $STATE"
  [[ "$STATE" == "READY" ]] && break
  sleep 10
done

# 3) Discover the cataloged table name (or set it explicitly if you prefer)
TABLES=$(aws glue get-tables --database-name "$GLUE_DB" --region "$AWS_REGION" --query "TableList[*].Name" --output text)
echo "Tables in $GLUE_DB: $TABLES"

# Use the first table by default
GOLD_TABLE=$(echo "$TABLES" | awk '{print $1}')
echo "Using Athena table: $GLUE_DB.$GOLD_TABLE"

run_athena () {
  local name="$1"
  local sql="$2"

  local qid state
  qid=$(aws athena start-query-execution \
    --query-string "$sql" \
    --query-execution-context Database="$GLUE_DB",Catalog=AwsDataCatalog \
    --result-configuration OutputLocation="$ATHENA_RESULTS_S3" \
    --work-group "$ATHENA_WORKGROUP" \
    --region "$AWS_REGION" \
    --query 'QueryExecutionId' --output text)

  while true; do
    state=$(aws athena get-query-execution \
      --query-execution-id "$qid" \
      --region "$AWS_REGION" \
      --query 'QueryExecution.Status.State' \
      --output text)

    if [[ "$state" == "SUCCEEDED" ]]; then
      break
    elif [[ "$state" == "FAILED" || "$state" == "CANCELLED" ]]; then
      echo "Query $name failed"
      aws athena get-query-execution --query-execution-id "$qid" --region "$AWS_REGION"
      return 1
    fi
    sleep 3
  done

  aws athena get-query-results \
    --query-execution-id "$qid" \
    --region "$AWS_REGION" > "$BUILD_DIR/${name}.json"

  echo "$name -> queryExecutionId=$qid -> saved to $BUILD_DIR/${name}.json"
}

# BI-style query: revenue by day
run_athena bi_daily_revenue "
SELECT event_date,
       SUM(COALESCE(price,0)) AS revenue
FROM ${GOLD_TABLE}
GROUP BY 1
ORDER BY 1;
"

# BI-style query: top categories
run_athena bi_top_categories "
SELECT category,
       COUNT(*) AS events,
       SUM(COALESCE(price,0)) AS revenue
FROM ${GOLD_TABLE}
GROUP BY 1
ORDER BY revenue DESC
LIMIT 10;
"

# Ad-hoc e-commerce query: product funnel / product events
run_athena adhoc_product_events "
SELECT product_id,
       COUNT(*) AS event_count
FROM ${GOLD_TABLE}
WHERE product_id IS NOT NULL
GROUP BY 1
ORDER BY event_count DESC
LIMIT 20;
"

echo "Athena query outputs saved under: $BUILD_DIR"