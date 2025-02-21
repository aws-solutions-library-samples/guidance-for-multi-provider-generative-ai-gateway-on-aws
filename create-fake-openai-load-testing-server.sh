
#!/bin/bash
set -aeuo pipefail

aws_region=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
echo $aws_region

APP_NAME=fakeserver
LITELLM_STACK_NAME="LitellmCdkStack"
FAKE_OPENAI_SERVER_STACK_NAME="LitellmFakeOpenaiLoadTestingServerCdkStack"

source .env

cd litellm-cdk
VPC_ID=$(jq -r ".\"${LITELLM_STACK_NAME}\".VpcId" ./outputs.json)
cd ..

cd litellm-fake-openai-load-testing-server-cdk
npm install

source .env.testing


if [ -n "$CPU_ARCHITECTURE" ]; then
    # Check if CPU_ARCHITECTURE is either "x86" or "arm"
    case "$CPU_ARCHITECTURE" in
        "x86"|"arm")
            ARCH="$CPU_ARCHITECTURE"
            ;;
        *)
            echo "Error: CPU_ARCHITECTURE must be either 'x86' or 'arm'"
            exit 1
            ;;
    esac
else
    # Determine architecture from system
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
fi

echo $ARCH

echo "about to build and push image"
cd docker
./docker-build-and-deploy.sh $APP_NAME $ARCH
cd ..

echo "about to deploy"
export JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1

cdk deploy "$FAKE_OPENAI_SERVER_STACK_NAME" --require-approval never \
--context vpcId=$VPC_ID \
--context certificateArn=$LOAD_TESTING_ENDPOINT_CERTIFICATE_ARN \
--context hostedZoneName=$LOAD_TESTING_ENDPOINT_HOSTED_ZONE_NAME \
--context domainName=$LOAD_TESTING_ENDPOINT_DOMAIN_NAME \
--context ecrFakeServerRepository=$APP_NAME \
--context architecture=$ARCH \
--outputs-file ./outputs.json

echo "deployed"

if [ $? -eq 0 ]; then
    LITELLM_ECS_CLUSTER=$(jq -r ".\"${FAKE_OPENAI_SERVER_STACK_NAME}\".FakeServerEcsCluster" ./outputs.json)
    LITELLM_ECS_TASK=$(jq -r ".\"${FAKE_OPENAI_SERVER_STACK_NAME}\".FakeServerEcsTask" ./outputs.json)
    
    aws ecs update-service \
        --cluster $LITELLM_ECS_CLUSTER \
        --service $LITELLM_ECS_TASK \
        --force-new-deployment \
        --desired-count 1 \
        --no-cli-pager
else
    echo "Deployment failed"
fi