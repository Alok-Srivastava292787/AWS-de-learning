#!/usr/bin/env bash
#----------------------------------------------
#Equivalent of “load data into Redshift via COPY” in the lakehouse world:

# -upload/copy raw clickstream CSV to S3 raw
# -run a Glue Spark ETL job to transform raw CSV into Gold Parquet
#    Glue ETL jobs are created with create-job, require a role and command, and glueetl is the Spark ETL command with a script stored in S3 via ScriptLocation.
#----------------------------------------------
#set -euo pipefail
source "${1:-./00_env.sh}"

# 1) Upload raw clickstream file to S3 raw zone
#aws s3 cp "$LOCAL_CLICKSTREAM_CSV" "${RAW_PREFIX}clickstream.csv" --region "$AWS_REGION"

if [[ ! -f "$LOCAL_CLICKSTREAM_CSV" ]]; then
  echo "ERROR: Local file does not exist: $LOCAL_CLICKSTREAM_CSV"
  exit 1
fi

# 2) Convert path for Windows AWS CLI if running in Git Bash / MINGW
UPLOAD_PATH="$LOCAL_CLICKSTREAM_CSV"
if command -v cygpath >/dev/null 2>&1; then
  UPLOAD_PATH=$(cygpath -w "$LOCAL_CLICKSTREAM_CSV")
fi

echo "Using upload path: $UPLOAD_PATH"

# 3) Try upload
aws s3 cp "$UPLOAD_PATH" "${RAW_PREFIX}clickstream.csv" --region "$AWS_REGION"

echo "Upload complete."

# 2) Build a Glue ETL script locally
GLUE_SCRIPT_LOCAL="$BUILD_DIR/clickstream_etl.py"

# 3) Upload the Glue script to S3
# aws s3 cp "$GLUE_SCRIPT_LOCAL" "${SCRIPT_PREFIX}clickstream_etl.py" --region "$AWS_REGION"
if [[ ! -f "$GLUE_SCRIPT_LOCAL" ]]; then
  echo "ERROR: Local file does not exist: $LOCAL_CLICKSTREAM_CSV"
  exit 1
fi

# 2) Convert path for Windows AWS CLI if running in Git Bash / MINGW
UPLOAD_PATH="$GLUE_SCRIPT_LOCAL"
if command -v cygpath >/dev/null 2>&1; then
  UPLOAD_PATH=$(cygpath -w "$GLUE_SCRIPT_LOCAL")
fi

echo "Using upload path: $UPLOAD_PATH"

# 3) Try upload
aws s3 cp "$UPLOAD_PATH" "${RAW_PREFIX}clickstream.csv" --region "$AWS_REGION"

echo "Upload complete."

# 4) Create or update the Glue job
if aws glue get-job --job-name "$GLUE_JOB" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Glue job exists; updating."
  aws glue update-job \
    --job-name "$GLUE_JOB" \
    --job-update "{
      \"Role\": \"${GLUE_ROLE}\",
      \"Command\": {
        \"Name\": \"glueetl\",
        \"ScriptLocation\": \"${SCRIPT_PREFIX}clickstream_etl.py\"
      },
      \"GlueVersion\": \"4.0\",
      \"WorkerType\": \"G.1X\",
      \"NumberOfWorkers\": 2,
      \"DefaultArguments\": {
        \"--RAW_PATH\": \"${RAW_PREFIX}\",
        \"--GOLD_PATH\": \"${GOLD_PREFIX}\"
      }
    }" \
    --region "$AWS_REGION"
else
  aws glue create-job \
    --name "$GLUE_JOB" \
    --role "$GLUE_ROLE" \
    --command "{
      \"Name\": \"glueetl\",
      \"ScriptLocation\": \"${SCRIPT_PREFIX}clickstream_etl.py\"
    }" \
    --glue-version "4.0" \
    --worker-type "G.1X" \
    --number-of-workers 2 \
    --default-arguments "{
      \"--RAW_PATH\": \"${RAW_PREFIX}\",
      \"--GOLD_PATH\": \"${GOLD_PREFIX}\"
    }" \
    --region "$AWS_REGION"
fi

# 5) Start the Glue ETL job
RUN_ID=$(aws glue start-job-run \
  --job-name "$GLUE_JOB" \
  --region "$AWS_REGION" \
  --query 'JobRunId' --output text)

echo "Started Glue job: $GLUE_JOB  run-id=$RUN_ID"