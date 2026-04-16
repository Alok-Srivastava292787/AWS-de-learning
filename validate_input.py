import boto3, json, logging 
logger = logging.getLogger() 
logger.setLevel(logging.INFO) 
 
s3 = boto3.client('s3') 
 
def lambda_handler(event, context): 
    bucket = event.get('bucket') 
    key    = event.get('key') 
    if not bucket or not key: 
        raise ValueError("Missing 'bucket' or 'key' in input") 
    try: 
        s3.head_object(Bucket=bucket, Key=key) 
        logger.info(f"Validated: s3://{bucket}/{key}") 
        return {**event, 'valid': True, 'message': f"Object exists: {key}"} 
    except s3.exceptions.ClientError as e: 
        if e.response['Error']['Code'] == '404': 
            logger.warning(f"Object not found: s3://{bucket}/{key}") 
            raise Exception(f"ValidationError: Object not found: 
s3://{bucket}/{key}") 
        raise 
