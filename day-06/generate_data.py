# generate_data.py
import pandas as pd
from faker import Faker
import random, uuid, datetime
fake = Faker()
CATEGORIES = ['Electronics','Clothing','Books','Home','Sports','Beauty']
# Products dataset (5,000 rows)
products = [{'product_id': f'P{i:05d}',
             'name': fake.catch_phrase(),
             'category': random.choice(CATEGORIES),
             'price': round(random.uniform(5, 2000), 2),
             'stock_qty': random.randint(0, 500),
             'supplier_id': f'SUP{random.randint(1,100):03d}',
             'created_at': fake.date_between('-2y','today').isoformat()}
            for i in range(1, 5001)]
# Customers dataset (10,000 rows)
customers = [{'customer_id': str(uuid.uuid4()),
              'name': fake.name(),
              'email': fake.email(),
              'city': fake.city(),
              'country': fake.country_code(),
              'tier': random.choice(['Bronze','Silver','Gold','Platinum']),
              'registered_at': fake.date_between('-3y','today').isoformat()}
             for _ in range(10000)]
# Orders dataset (50,000 rows)
cust_ids = [c['customer_id'] for c in customers]
prod_ids = [p['product_id'] for p in products]
orders = [{'order_id': str(uuid.uuid4()),
           'customer_id': random.choice(cust_ids),
           'product_id': random.choice(prod_ids),
           'quantity': random.randint(1,10),
           'unit_price': round(random.uniform(5, 2000), 2),
           'status': 
random.choice(['PLACED','SHIPPED','DELIVERED','RETURNED','CANCELLED']),
           'order_ts': fake.date_time_between('-1y','now').isoformat()}
          for _ in range(50000)]
pd.DataFrame(products).to_csv('products.csv', index=False)

pd.DataFrame(customers).to_csv('customers.csv', index=False)
pd.DataFrame(orders).to_csv('orders.csv', index=False)
print('Generated: products.csv (5k), customers.csv (10k), orders.csv (50k)')