#!/usr/bin/env bash
#set -euo pipefail
source "${1:-./00_env.sh}"

ROLE_NAME="${LAMBDA_NAME}-role"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
TRUST_JSON="./lambda-trust-policy.json"
POLICY_JSON="./lambda-ddb-policy.json"
ZIP_PATH="./${LAMBDA_NAME}.zip"
LAMBDA_SRC="./lambda_function.py"

cat > "$TRUST_JSON" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

cat > "$POLICY_JSON" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["dynamodb:GetItem"],
    "Resource": "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${PRODUCTS_TABLE}"
  }]
}
EOF

# Create/update IAM role
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "IAM role $ROLE_NAME already exists."
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_JSON" >/dev/null

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "${LAMBDA_NAME}-ddb" \
    --policy-document "file://$POLICY_JSON"

  sleep 15
fi

# Function code
cat > "$LAMBDA_SRC" <<'PY'
import json, os, boto3

TABLE = os.environ["PRODUCTS_TABLE"]
ddb = boto3.client("dynamodb")

def lambda_handler(event, context):
    pid = None
    if isinstance(event, dict):
        path_params = event.get("pathParameters") or {}
        pid = path_params.get("id")

    if not pid:
        return {
            "statusCode": 400,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": "Missing product id"})
        }

    resp = ddb.get_item(
        TableName=TABLE,
        Key={"product_id": {"S": pid}}
    )

    item = resp.get("Item")
    if not item:
        return {
            "statusCode": 404,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"message": f"Product {pid} not found"})
        }

    simple = {k: list(v.values())[0] for k, v in item.items()}
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(simple)
    }
PY

# Zip the function
#(
#  cd "./"
#  zip -q -j "$ZIP_PATH" "$LAMBDA_SRC"
#)

# Create or update Lambda
if aws lambda get-function --function-name "$LAMBDA_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "$LAMBDA_NAME" \
    --zip-file "fileb://${ZIP_PATH}" \
    --region "$AWS_REGION" >/dev/null

  aws lambda update-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --runtime "$LAMBDA_RUNTIME" \
    --role "$ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --environment "Variables={PRODUCTS_TABLE=$PRODUCTS_TABLE}" \
    --region "$AWS_REGION" >/dev/null
else
  aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --runtime "$LAMBDA_RUNTIME" \
    --role "$ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://${ZIP_PATH}" \
    --environment "Variables={PRODUCTS_TABLE=$PRODUCTS_TABLE}" \
    --region "$AWS_REGION" >/dev/null
fi

# Wait until Lambda is Active
for i in $(seq 1 30); do
  state=$(aws lambda get-function-configuration \
    --function-name "$LAMBDA_NAME" \
    --region "$AWS_REGION" \
    --query 'State' --output text)
  [[ "$state" == "Active" ]] && break
  sleep 3
done

# Recreate API if it already exists
API_ID=$(aws apigateway get-rest-apis \
  --region "$AWS_REGION" \
  --query "items[?name=='$API_NAME'].id | [0]" \
  --output text)

if [[ "$API_ID" != "None" && -n "$API_ID" ]]; then
  aws apigateway delete-rest-api --rest-api-id "$API_ID" --region "$AWS_REGION"
  sleep 3
fi

API_JSON=$(aws apigateway create-rest-api --name "$API_NAME" --region "$AWS_REGION")
API_ID=$(echo "$API_JSON" | python -c "import sys,json; print(json.load(sys.stdin)['id'])")
ROOT_ID=$(echo "$API_JSON" | python -c "import sys,json; print(json.load(sys.stdin)['rootResourceId'])")

PRODUCTS_RES_ID=$(aws apigateway create-resource \
  --rest-api-id "$API_ID" \
  --parent-id "$ROOT_ID" \
  --path-part products \
  --region "$AWS_REGION" \
  --query 'id' --output text)

ITEM_RES_ID=$(aws apigateway create-resource \
  --rest-api-id "$API_ID" \
  --parent-id "$PRODUCTS_RES_ID" \
  --path-part '{id}' \
  --region "$AWS_REGION" \
  --query 'id' --output text)

aws apigateway put-method \
  --rest-api-id "$API_ID" \
  --resource-id "$ITEM_RES_ID" \
  --http-method GET \
  --authorization-type NONE \
  --request-parameters method.request.path.id=true \
  --region "$AWS_REGION" >/dev/null

LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region "$AWS_REGION" \
  --query 'Configuration.FunctionArn' --output text)

INTEGRATION_URI="arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"

aws apigateway put-integration \
  --rest-api-id "$API_ID" \
  --resource-id "$ITEM_RES_ID" \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "$INTEGRATION_URI" \
  --region "$AWS_REGION" >/dev/null

SOURCE_ARN="arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*/GET/products/*"

set +e
aws lambda add-permission \
  --function-name "$LAMBDA_NAME" \
  --statement-id "apigw-${API_ID}" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "$SOURCE_ARN" \
  --region "$AWS_REGION" >/dev/null 2>&1
set -e

aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name "$API_STAGE" \
  --region "$AWS_REGION" >/dev/null

echo "API deployed."
echo "Test with:"
echo "curl https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/${API_STAGE}/products/P100"