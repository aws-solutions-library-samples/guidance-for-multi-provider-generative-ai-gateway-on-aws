#!/bin/bash

if [ $# -ne 2 ]; then
  echo "Usage: $0 <APP_NAME> <BUILD_FROM_SOURCE>"
  exit 1
fi

APP_NAME=$1
BUILD_FROM_SOURCE=$(echo "$2" | tr '[:upper:]' '[:lower:]')

# check again if LITELLM_VERSION is set if script is used standalone
source .env
if [[ (-z "$LITELLM_VERSION") || ("$LITELLM_VERSION" == "placeholder") ]]; then
    echo "LITELLM_VERSION must be set in .env file"
    exit 1
fi

if [ "$BUILD_FROM_SOURCE" = "true" ]; then
    echo "Building from source..."
    if [ ! -d "litellm-source" ]; then
        echo "Fetching source for LiteLLM version ${LITELLM_VERSION}"
        mkdir litellm-source
        curl -L https://github.com/BerriAI/litellm/archive/refs/tags/${LITELLM_VERSION}.tar.gz | tar -xz -C litellm-source --strip-components=1
    else
        LITELLM_SOURCE_VERSION=$(yq '.tool.poetry.version' litellm-source/pyproject.toml)
        if [ v"$LITELLM_SOURCE_VERSION" != "$LITELLM_VERSION" ]; then
            echo "Your specified version ${LITELLM_VERSION} does not match the source version ${LITELLM_SOURCE_VERSION}"
            echo "Please remove the litellm-source directory manually and re-run this script when you change the version number"
            exit 1
        else
            echo "Source version ${LITELLM_VERSION} already exists, skipping fetching".
        fi
    fi

    cd litellm-source
fi

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

ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH="linux/amd64"
        ;;
    arm64)
        ARCH="linux/arm64"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo $ARCH

aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
docker build --platform $ARCH --build-arg LITELLM_VERSION=${LITELLM_VERSION} -t $APP_NAME\:${LITELLM_VERSION} .
echo "Tagging image with ${APP_NAME}:${LITELLM_VERSION}"
docker tag $APP_NAME\:${LITELLM_VERSION} $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$APP_NAME\:${LITELLM_VERSION}
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$APP_NAME\:${LITELLM_VERSION}
