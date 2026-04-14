import boto3
import json
import base64
import time
import logging
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3', region_name='us-east-1')

def lambda_handler(event, context):
    """
    Consume SQS messages and write to S3 as Parquet-like JSON format
    This replaces the Kinesis->Firehose->Parquet pipeline
    """
    bucket = event.get('bucket_name', 'my-datalake-lab-alok')
    records = []
    
    # Process messages from SQS
    for record in event.get('Records', []):
        try:
            body = json.loads(record['body'])
            # Add ingestion timestamp
            body['ingestion_ts'] = int(time.time())
            # Mask email PII
            if 'email' in body:
                local, domain = body['email'].split('@') if '@' in body['email'] else (body['email'], '')
                body['email'] = local[0] + '***@' + domain if domain else '***'
            records.append(body)
            logger.info(f"Processed: {body['user_id']} - {body['event']}")
        except Exception as e:
            logger.error(f"Error processing record: {e}")
    
    # Write batch to S3
    if records:
        timestamp = datetime.utcnow()
        year = timestamp.strftime('%Y')
        month = timestamp.strftime('%m')
        key = f"processed/clickstream/year={year}/month={month}/batch-{int(time.time())}.json"
        
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=json.dumps(records, indent=2),
            ContentType='application/json'
        )
        logger.info(f"Wrote {len(records)} records to s3://{bucket}/{key}")
    
    return {
        'statusCode': 200,
        'body': json.dumps(f"Processed {len(records)} records")
    }

