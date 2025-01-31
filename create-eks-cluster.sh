#!/bin/bash
set -aeuo pipefail

EKS_CLUSTER_STACK_NAME="LitellmEksClusterCdkStack"

ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH="x86"
        ;;
    arm64)
        ARCH="arm"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo $ARCH

cd litellm-eks-cluster-cdk
echo "Installing eks cluster dependencies..."
npm install
npm run build
npm install
npm run build
echo "Deploying the eks cluster CDK stack..."

cdk deploy "$EKS_CLUSTER_STACK_NAME" \
--outputs-file ./outputs.json

if [ $? -eq 0 ]; then
    echo "Deployment successful. Extracting outputs..."
    VPC_ID=$(jq -r ".\"${EKS_CLUSTER_STACK_NAME}\".VpcId" ./outputs.json)
    EKS_CLUSTER_NAME=$(jq -r ".\"${EKS_CLUSTER_STACK_NAME}\".EksClusterName" ./outputs.json)
    
    echo "VPC_ID $VPC_ID"
    echo "EKS_CLUSTER_NAME $EKS_CLUSTER_NAME"
else
    echo "Deployment failed"
fi