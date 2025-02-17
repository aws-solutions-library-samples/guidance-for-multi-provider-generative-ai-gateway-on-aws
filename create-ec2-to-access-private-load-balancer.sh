#!/bin/bash
set -aeuo pipefail

aws_region=$(aws configure get region)
echo $aws_region

LITELLM_STACK_NAME="LitellmCdkStack"
PRIVATE_LOAD_BALANCER_EC2_STACK_NAME="LitellmPrivateLoadBalancerEc2Stack"

source .env

cd litellm-cdk
VPC_ID=$(jq -r ".\"${LITELLM_STACK_NAME}\".VpcId" ./outputs.json)
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