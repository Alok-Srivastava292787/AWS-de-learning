#!/usr/bin/env bash
#-----------------------------------------------
#This part doesn’t need Redshift either — it remains a normal DynamoDB exercise. 
#  - create-table creates the table asynchronously and 
#  - batch-write-item loads multiple items in one request.
#-----------------------------------------------

#set -euo pipefail
source "${1:-./00_env.sh}"

PYTHON_BIN="${PYTHON_BIN:-python}"
BATCH_DIR="./ddb_batches"
mkdir -p "$BATCH_DIR"

echo "Using CSV file: $PRODUCTS_CSV"
echo "Target DynamoDB table: $PRODUCTS_TABLE"

# ------------------------------------------------------------
# 1) Create DynamoDB table if it does not exist
# ------------------------------------------------------------
if aws dynamodb describe-table \
  --table-name "$PRODUCTS_TABLE" \
  --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "DynamoDB table $PRODUCTS_TABLE already exists."
else
  echo "Creating DynamoDB table: $PRODUCTS_TABLE"
  aws dynamodb create-table \
    --table-name "$PRODUCTS_TABLE" \
    --attribute-definitions AttributeName="$DDB_HASH_KEY",AttributeType=S \
    --key-schema AttributeName="$DDB_HASH_KEY",KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"

  aws dynamodb wait table-exists \
    --table-name "$PRODUCTS_TABLE" \
    --region "$AWS_REGION"
fi

# ------------------------------------------------------------
# 2) Convert CSV -> DynamoDB batch JSON files (25 items each)
# ------------------------------------------------------------
echo "Converting CSV to DynamoDB batch JSON... "

PRODUCTS_TABLE="$PRODUCTS_TABLE" \
PRODUCTS_CSV="$PRODUCTS_CSV" \
DDB_NUMBER_FIELDS="$DDB_NUMBER_FIELDS" \
BATCH_DIR="$BATCH_DIR" \
"$PYTHON_BIN" - <<'PY'
import csv
import json
import os
from pathlib import Path

table_name = os.environ["PRODUCTS_TABLE"]
csv_path = os.environ["PRODUCTS_CSV"]
batch_dir = Path(os.environ["BATCH_DIR"])
number_fields = set(
    f.strip() for f in os.environ.get("DDB_NUMBER_FIELDS", "").split(",") if f.strip()
)

batch_dir.mkdir(parents=True, exist_ok=True)

rows = []
with open(csv_path, newline="", encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        item = {}
        for key, value in row.items():
            if value is None:
                continue
            value = value.strip()
            if value == "":
                continue

            if key in number_fields:
                item[key] = {"N": value}
            else:
                item[key] = {"S": value}

        rows.append({"PutRequest": {"Item": item}})

batch_size = 25
for i in range(0, len(rows), batch_size):
    chunk = rows[i:i+batch_size]

    # IMPORTANT: write only the RequestItems map value
    payload = {
        table_name: chunk
    }

    out_file = batch_dir / f"batch_{i//batch_size + 1:03d}.json"
    with open(out_file, "w", encoding="utf-8") as wf:
        json.dump(payload, wf, indent=2)

print(f"Created {((len(rows)-1)//batch_size)+1 if rows else 0} batch files in {batch_dir}")
PY
# ------------------------------------------------------------
# 3) Upload all batches to DynamoDB with retry for UnprocessedItems
# ------------------------------------------------------------
echo "Loading batches into DynamoDB..."

for batch_file in "$BATCH_DIR"/batch_*.json; do
  [ -e "$batch_file" ] || continue

  echo "Processing $batch_file"

  current_payload="$batch_file"
  attempt=1

  while true; do
    response_file="$BATCH_DIR/response.json"

    aws dynamodb batch-write-item \
      --request-items "file://$current_payload" \
      --region "$AWS_REGION" > "$response_file"

    # Check if UnprocessedItems is empty
    has_unprocessed=$(
      RESPONSE_FILE="$response_file" \
      PRODUCTS_TABLE="$PRODUCTS_TABLE" \
      "$PYTHON_BIN" - <<'PY'
import json
import os

response_file = os.environ["RESPONSE_FILE"]
table_name = os.environ["PRODUCTS_TABLE"]

with open(response_file, encoding="utf-8") as f:
    data = json.load(f)

items = data.get("UnprocessedItems", {}).get(table_name, [])
print("yes" if items else "no")
PY
    )

    if [[ "$has_unprocessed" == "no" ]]; then
      echo "Batch succeeded: $batch_file"
      break
    fi

    echo "UnprocessedItems found, retrying attempt $attempt..."

    retry_file="$BATCH_DIR/retry.json"

    RESPONSE_FILE="$response_file" \
    RETRY_FILE="$retry_file" \
    "$PYTHON_BIN" - <<'PY'
import json
import os

response_file = os.environ["RESPONSE_FILE"]
retry_file = os.environ["RETRY_FILE"]

with open(response_file, encoding="utf-8") as f:
    data = json.load(f)

with open(retry_file, "w", encoding="utf-8") as f:
    json.dump({"RequestItems": data["UnprocessedItems"]}, f, indent=2)
PY

    current_payload="$retry_file"
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
done

echo "Load complete."

echo "Sample verification:"
aws dynamodb scan \
  --table-name "$PRODUCTS_TABLE" \
  --max-items 5 \
  --region "$AWS_REGION"