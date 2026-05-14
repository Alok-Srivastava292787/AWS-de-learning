# CLI alternative -- create folders via empty object upload
# BUCKET=shopstream-datalake-$(aws sts get-caller-identity --query Account --output text)
BUCKET=shopstream-datalake-463183325212-us-east-1-an
for PREFIX in raw/batch/products raw/batch/customers raw/batch/orders \
              raw/streaming/orders silver/orders silver/products \
gold/sales_summary; do
  aws s3api put-object --bucket $BUCKET --key $PREFIX/.keep
done
echo 'Folder structure created in' $BUCKE