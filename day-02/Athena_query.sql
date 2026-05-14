-- create a database/table
CREATE EXTERNAL TABLE IF NOT EXISTS lab_datalake_db.sales_curated ( 
    order_id     INT, 
    customer_id  STRING, 
    product      STRING, 
    amount       DOUBLE, 
    order_date   DATE 
) 
PARTITIONED BY (region STRING, year STRING) 
STORED AS PARQUET 
LOCATION 's3://my-datalake-lab-alok/curated/sales/' 
TBLPROPERTIES ('parquet.compress'='SNAPPY'); 

-- query 1
CREATE EXTERNAL TABLE IF NOT EXISTS lab_datalake_db.sales_curated ( 
    order_id     INT, 
    customer_id  STRING, 
    product      STRING, 
    amount       DOUBLE, 
    order_date   DATE 
) 
PARTITIONED BY (region STRING, year STRING) 
STORED AS PARQUET 
LOCATION 's3://my-datalake-lab-alok/curated/sales/' 
TBLPROPERTIES ('parquet.compress'='SNAPPY'); 

--query 2
SELECT product, SUM(amount) AS revenue 
FROM lab_datalake_db.sales_curated 
GROUP BY product 
ORDER BY revenue DESC 
LIMIT 10;

-- Query 3: CTAS — create pre-aggregated summary table 
-- didn't work with external location
CREATE TABLE lab_datalake_db.daily_summary 
WITH (format='PARQUET', external_location='s3://my-datalake-lab-alok/curated/daily_summary/') 
AS 
SELECT order_date, region, SUM(amount) AS daily_revenue 
FROM lab_datalake_db.sales_curated 
GROUP BY order_date, region; 
 
Step 3 — Create an Athena View -- Create a view for high-value orders 
CREATE OR REPLACE VIEW lab_datalake_db.high_value_orders AS 
SELECT order_id, customer_id, product, amount, order_date, region 
FROM lab_datalake_db.sales_curated 
WHERE amount > 500; 
 -- Query the view 
SELECT * FROM lab_datalake_db.high_value_orders 
ORDER BY amount DESC;