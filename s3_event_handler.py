import json, logging 
logger = logging.getLogger() 
logger.setLevel(logging.INFO) 
 
def lambda_handler(event, context): 
    for record in event.get('Records', []): 
        bucket = record['s3']['bucket']['name'] 
        key    = record['s3']['object']['key'] 
        size   = record['s3']['object'].get('size', 0) 
        etime  = record['eventTime'] 
        logger.info(f"NEW OBJECT | bucket={bucket} | key={key} | size={size}B | time={etime}") 
        # TODO: trigger Glue crawler or Step Functions here 
    return {'statusCode': 200, 'body': f"Processed {len(event['Records'])} record(s)"} 
