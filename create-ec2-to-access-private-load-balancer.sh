#!/bin/bash
set -aeuo pipefail

aws_region=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
echo $aws_region

PRIVATE_LOAD_BALANCER_EC2_STACK_NAME="LitellmPrivateLoadBalancerEc2Stack"

source .env

cd litellm-terraform-stack
VPC_ID=$(terraform output -raw vpc_id)
cd ..

cd litellm-private-load-balancer-ec2
npm install

source .ec2.env

echo "about to deploy"
export JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1

cdk deploy "$PRIVATE_LOAD_BALANCER_EC2_STACK_NAME" --require-approval never \
--context vpcId=$VPC_ID \
--context keyPairName=$KEY_PAIR_NAME \
--outputs-file ./outputs.json

echo "deployed"