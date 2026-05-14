import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, to_timestamp, to_date

args = getResolvedOptions(sys.argv, ["JOB_NAME", "RAW_PATH", "GOLD_PATH"])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

raw_path = args["RAW_PATH"]
gold_path = args["GOLD_PATH"]

df = (
    spark.read
         .option("header", True)
         .option("inferSchema", True)
         .csv(raw_path)
)

df2 = (
    df.withColumn("event_ts", to_timestamp(col("event_ts")))
      .withColumn("event_date", to_date(col("event_ts")))
)

(df2.write
    .mode("overwrite")
    .format("parquet")
    .partitionBy("event_date")
    .save(gold_path))

job.commit()