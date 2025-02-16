#!/bin/bash

if [ $# -ne 2 ]; then
  echo "Usage: $0 <APP_NAME> <ARCH>"
  exit 1
fi

APP_NAME=$1
ARCH=$2

AWS_REGION=$(aws configure get region)
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

# Check if the repository already exists
REPO_EXISTS=$(aws ecr describe-repositories --repository-names $APP_NAME 2>/dev/null)

if [ -z "$REPO_EXISTS" ]; then
    # Repository does not exist, create it with tag
    aws ecr create-repository --repository-name $APP_NAME --tags Key=project,Value=llmgateway
else
    echo "Repository $APP_NAME already exists, checking tags..."
    
    # Get current tags for the repository
    CURRENT_TAGS=$(aws ecr list-tags-for-resource --resource-arn arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${APP_NAME})
    
    # Check if project=llmgateway tag exists
    if ! echo "$CURRENT_TAGS" | grep -q '"Key": "project".*"Value": "llmgateway"'; then
        echo "Adding project=llmgateway tag..."
        aws ecr tag-resource \
            --resource-arn arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${APP_NAME} \
            --tags Key=project,Value=llmgateway
    else
        echo "Tag project=llmgateway already exists."
    fi
fi

echo $ARCH
case $ARCH in
    "x86")
        DOCKER_ARCH="linux/amd64"
        ;;
    "arm")
        DOCKER_ARCH="linux/arm64"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo $DOCKER_ARCH

aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
docker build --platform $DOCKER_ARCH -t $APP_NAME .
docker tag $APP_NAME\:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$APP_NAME\:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$APP_NAME\:latest