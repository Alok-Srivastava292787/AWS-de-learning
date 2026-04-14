export BUCKET_NAME="my-datalake-lab-alok" 
export REGION="us-east-1" 
 
# Create the bucket 
aws s3api create-bucket --bucket $BUCKET_NAME --region $REGION 
 
# Enable versioning 
aws s3api put-bucket-versioning --bucket $BUCKET_NAME --versioning-configuration Status=Enabled
