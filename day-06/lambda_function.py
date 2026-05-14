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
