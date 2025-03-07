#!/bin/bash
set -aeuo pipefail

aws_region=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
echo $aws_region

# Load environment variables from .env file
source .env

# Check if config.yaml exists
if [ ! -f "config/config.yaml" ]; then
  echo "config/config.yaml does not exist, can't upload to S3"
  exit 1
fi

cd litellm-terraform-stack
ConfigBucketName=$(terraform output -raw ConfigBucketName)
cd ..

echo "uploading config.yaml to bucket $ConfigBucketName"  # This was missing the closing quote

# Add the actual upload command
aws s3 cp config/config.yaml s3://$ConfigBucketName/config.yaml --region $aws_region

echo "Upload complete"

cd litellm-terraform-stack
if [ "$DEPLOYMENT_PLATFORM" = "ECS" ]; then
    LITELLM_ECS_CLUSTER=$(terraform output -raw LitellmEcsCluster)
    LITELLM_ECS_TASK=$(terraform output -raw LitellmEcsTask)

    echo "Rebooting ECS Task $LITELLM_ECS_TASK on ECS cluster $LITELLM_ECS_CLUSTER"

    aws ecs update-service \
        --cluster $LITELLM_ECS_CLUSTER \
        --service $LITELLM_ECS_TASK \
        --force-new-deployment \
        --desired-count $DESIRED_CAPACITY \
        --no-cli-pager
fi

if [ "$DEPLOYMENT_PLATFORM" = "EKS" ]; then
    EKS_CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
    EKS_DEPLOYMENT_NAME=$(terraform output -raw eks_deployment_name)
    echo "Rebooting EKS deployment $EKS_DEPLOYMENT_NAME on EKS cluster $EKS_CLUSTER_NAME"

    aws eks update-kubeconfig --region $aws_region --name $EKS_CLUSTER_NAME
    kubectl rollout restart deployment $EKS_DEPLOYMENT_NAME
fi
