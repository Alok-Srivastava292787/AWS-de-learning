import boto3
import json
import random
import time

sqs = boto3.client('sqs', region_name='us-east-1')
QUEUE_URL = 'https://sqs.us-east-1.amazonaws.com/463183325212/clickstream-events'  # Update with your queue URL
PAGES   = ['home', 'product', 'cart', 'checkout', 'confirmation', 'search']
EVENTS  = ['view', 'click', 'scroll', 'purchase', 'add_to_cart', 'search']
USERS   = [f"u{i:04d}" for i in range(1, 21)]   # 20 unique users

print(f"Sending 100 clickstream events to SQS Queue: {QUEUE_URL}")

for i in range(100):
    user = random.choice(USERS)
    message = {
        'user_id':    user,
        'event':      random.choice(EVENTS),
        'page':       random.choice(PAGES),
        'session_id': f"sess-{random.randint(1000,9999)}",
        'email':      f"{user}@example.com",
        'ts':         int(time.time())
    }
    
    # Send to SQS
    response = sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message),
        MessageGroupId=user  # FIFO grouping (optional)
    )
    
    if (i + 1) % 20 == 0:
        print(f"Sent {i + 1}/100 messages...")

print("✓ All 100 messages sent to SQS Queue")
