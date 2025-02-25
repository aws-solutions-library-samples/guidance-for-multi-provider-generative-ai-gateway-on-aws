#!/bin/bash
set -aeuo pipefail

aws_region=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
echo $aws_region

# Load environment variables from .env file
source .env

echo "EC2_KEY_PAIR_NAME: $EC2_KEY_PAIR_NAME" 

# Check if bucket exists
if aws s3api head-bucket --bucket "$TERRAFORM_S3_BUCKET_NAME" 2>/dev/null; then
    echo "Terraform Bucket $TERRAFORM_S3_BUCKET_NAME already exists, skipping creation"
else
    echo "Creating bucket $TERRAFORM_S3_BUCKET_NAME..."
    aws s3 mb "s3://$TERRAFORM_S3_BUCKET_NAME" --region $aws_region
    echo "Terraform Bucket created successfully"
fi

cd litellm-terraform-stack
VPC_ID=$(terraform output -raw vpc_id)
cd ..

cd litellm-private-load-balancer-ec2-terraform

echo "about to deploy"

cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-ec2.tfstate"
region  = "${aws_region}"
encrypt = true
EOF
echo "Generated backend.hcl configuration"

terraform init -backend-config=backend.hcl

export TF_VAR_vpc_id=$VPC_ID
export TF_VAR_key_pair_name=$EC2_KEY_PAIR_NAME

terraform apply -auto-approve
echo "deployed"