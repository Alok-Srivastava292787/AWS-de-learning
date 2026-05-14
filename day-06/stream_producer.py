# stream_producer.py -- simulate real-time order events
import boto3, json, random, time, uuid
from datetime import datetime
kinesis = boto3.client('kinesis', region_name='us-east-1')
STREAM = 'shopstream-orders-stream'
STATUSES = ['PLACED', 'PAYMENT_CONFIRMED', 'SHIPPED', 'DELIVERED']
def generate_event():
    return {
        'event_id': str(uuid.uuid4()),
        'event_type': 'ORDER_EVENT',
        'order_id': str(uuid.uuid4()),
        'customer_id': f'CUST{random.randint(1,10000):05d}',
        'product_id': f'P{random.randint(1,5000):05d}',
        'quantity': random.randint(1, 5),
        'amount': round(random.uniform(10, 1500), 2),
        'status': random.choice(STATUSES),
        'timestamp': datetime.utcnow().isoformat()
    }
print('Streaming 200 events to Kinesis...')
for i in range(200):
    event = generate_event()
    kinesis.put_record(
        StreamName=STREAM,
        Data=json.dumps(event),
        PartitionKey=event['customer_id']
    )
    if i % 20 == 0:
        print(f'  Sent {i+1} events')
    time.sleep(0.1)
print('Done. Check S3 raw/streaming/orders/ in ~90 seconds.')