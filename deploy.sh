#!/bin/bash
set -aeuo pipefail

# Parse command line arguments
if [ ! -f "config/config.yaml" ]; then
    echo "config/config.yaml does not exist, creating it from default-config.yaml"
    cp config/default-config.yaml config/config.yaml
fi

if [ ! -f ".env" ]; then
    echo "Error: .env file missing. Creating it from .env.template"
    cp .env.template .env
fi

aws_region=$(aws configure get region)
echo $aws_region

SKIP_BUILD=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-build]"
            exit 1
            ;;
    esac
done

APP_NAME=litellm
MIDDLEWARE_APP_NAME=middleware
STACK_NAME="LitellmCdkStack"
LOG_BUCKET_STACK_NAME="LogBucketCdkStack"
DATABASE_STACK_NAME="LitellmDatabaseCdkStack"
EKS_CLUSTER_PRE_SETUP_STACK_NAME="LitellmEksClusterPreSetupCdkStack"
EKS_CLUSTER_NODE_GROUP_STACK_NAME="LitellmEksClusterNodeGroupCdkStack"

# Load environment variables from .env file
source .env

if [[ (-z "$LITELLM_VERSION") || ("$LITELLM_VERSION" == "placeholder") ]]; then
    echo "LITELLM_VERSION must be set in .env file"
    exit 1
fi

if [ -z "$CERTIFICATE_ARN" ] || [ -z "$DOMAIN_NAME" ]; then
    echo "Error: CERTIFICATE_ARN and DOMAIN_NAME must be set in .env file"
    exit 1
fi

echo "Certificate Arn: " $CERTIFICATE_ARN
echo "Domain Name: " $DOMAIN_NAME
echo "OKTA_ISSUER: $OKTA_ISSUER"
echo "OKTA_AUDIENCE: $OKTA_AUDIENCE"
echo "LiteLLM Version: " $LITELLM_VERSION
echo "Skipping container build: " $SKIP_BUILD
echo "Build from source: " $BUILD_FROM_SOURCE

echo "OPENAI_API_KEY: $OPENAI_API_KEY"
echo "AZURE_OPENAI_API_KEY: $AZURE_OPENAI_API_KEY"
echo "AZURE_API_KEY: $AZURE_API_KEY"
echo "ANTHROPIC_API_KEY: $ANTHROPIC_API_KEY"
echo "GROQ_API_KEY: $GROQ_API_KEY"
echo "COHERE_API_KEY: $COHERE_API_KEY"
echo "CO_API_KEY: $CO_API_KEY"
echo "HF_TOKEN: $HF_TOKEN"
echo "HUGGINGFACE_API_KEY: $HUGGINGFACE_API_KEY"
echo "DATABRICKS_API_KEY: $DATABRICKS_API_KEY"
echo "GEMINI_API_KEY: $GEMINI_API_KEY"
echo "CODESTRAL_API_KEY: $CODESTRAL_API_KEY"
echo "MISTRAL_API_KEY: $MISTRAL_API_KEY"
echo "AZURE_AI_API_KEY: $AZURE_AI_API_KEY"
echo "NVIDIA_NIM_API_KEY: $NVIDIA_NIM_API_KEY"
echo "XAI_API_KEY: $XAI_API_KEY"
echo "PERPLEXITYAI_API_KEY: $PERPLEXITYAI_API_KEY"
echo "GITHUB_API_KEY: $GITHUB_API_KEY"
echo "DEEPSEEK_API_KEY: $DEEPSEEK_API_KEY"
echo "AI21_API_KEY: $AI21_API_KEY"
echo "LANGSMITH_API_KEY: $LANGSMITH_API_KEY"
echo "LANGSMITH_PROJECT: $LANGSMITH_PROJECT"
echo "LANGSMITH_DEFAULT_RUN_NAME: $LANGSMITH_DEFAULT_RUN_NAME"
echo "DEPLOYMENT_PLATFORM: $DEPLOYMENT_PLATFORM"
echo "VPC_ID: $VPC_ID"
echo "EKS_CLUSTER_NAME: $EKS_CLUSTER_NAME"
echo "EKS_OIDC_URL: $EKS_OIDC_URL"

if [ "$SKIP_BUILD" = false ]; then
    echo "Building and pushing docker image..."
    ./docker-build-and-deploy.sh $APP_NAME $BUILD_FROM_SOURCE
else
    echo "Skipping docker build and deploy step..."
fi

cd middleware
./docker-build-and-deploy.sh $MIDDLEWARE_APP_NAME
cd ..

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

cd litellm-s3-log-bucket-cdk
echo "Installing log bucket dependencies..."
npm install
npm run build
echo "Deploying the log bucket CDK stack..."

cdk deploy "$LOG_BUCKET_STACK_NAME" \
--outputs-file ./outputs.json

if [ $? -eq 0 ]; then
    echo "Log Bucket Deployment successful. Extracting outputs..."
    LOG_BUCKET_NAME=$(jq -r ".\"${LOG_BUCKET_STACK_NAME}\".LogBucketName" ./outputs.json)
    LOG_BUCKET_ARN=$(jq -r ".\"${LOG_BUCKET_STACK_NAME}\".LogBucketArn" ./outputs.json)

    CONFIG_PATH="../config/config.yaml"

    # Check if yq is installed
    if ! command -v yq &> /dev/null; then
        echo "Error: yq is not installed. Please install it first."
        exit 1
    fi

    # Preliminary check to ensure config/config.yaml is valid YAML
    if ! yq e '.' "$CONFIG_PATH" >/dev/null 2>&1; then
        echo "Error: config/config.yaml is not valid YAML."
        exit 1
    fi
    
    # Check if s3_callback_params section exists and is not commented out
    if yq e '.litellm_settings.s3_callback_params' "$CONFIG_PATH" | grep -q "^[^#]"; then
        echo "Found s3_callback_params section. Updating values..."
        
        # Update both values using yq
        yq e ".litellm_settings.s3_callback_params.s3_bucket_name = \"$LOG_BUCKET_NAME\" | 
            .litellm_settings.s3_callback_params.s3_region_name = \"$aws_region\"" -i "$CONFIG_PATH"
        
        echo "Updated config.yaml with bucket name: $LOG_BUCKET_NAME and region: $aws_region"
    else
        echo "s3_callback_params section not found or is commented out in $CONFIG_PATH"
    fi

else
    echo "Log bucket Deployment failed"
fi

cd ..

# Check if required environment variables exist and are not empty
if [ -n "${LANGSMITH_API_KEY}" ] && [ -n "${LANGSMITH_PROJECT}" ] && [ -n "${LANGSMITH_DEFAULT_RUN_NAME}" ]; then

    # Update the success callback array, creating them if they don't exist
    yq eval '.litellm_settings.success_callback = ((.litellm_settings.success_callback // []) + ["langsmith"] | unique)' -i config/config.yaml

    echo "Updated config.yaml with 'langsmith' added to success callback array"
fi

cd litellm-database-cdk
echo "Installing dependencies for database cdk..."
npm install
echo "Deploying the database CDK stack..."
cdk deploy "$DATABASE_STACK_NAME" \
--context vpcId=$VPC_ID \
--outputs-file ./outputs.json

if [ $? -eq 0 ]; then
    echo "Deployment successful. Extracting outputs..."
    VPC_ID=$(jq -r ".\"${DATABASE_STACK_NAME}\".VpcId" ./outputs.json)
    RDS_LITELLM_HOSTNAME=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsLitellmHostname" ./outputs.json)
    RDS_LITELLM_SECRET_ARN=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsLitellmSecretArn" ./outputs.json)
    RDS_MIDDLEWARE_HOSTNAME=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsMiddlewareHostname" ./outputs.json)
    RDS_MIDDLEWARE_SECRET_ARN=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsMiddlewareSecretArn" ./outputs.json)
    REDIS_HOST_NAME=$(jq -r ".\"${DATABASE_STACK_NAME}\".RedisHostName" ./outputs.json)
    REDIS_PORT=$(jq -r ".\"${DATABASE_STACK_NAME}\".RedisPort" ./outputs.json)
    RDS_SECURITY_GROUP_ID=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsSecurityGroupId" ./outputs.json)
    REDIS_SECURITY_GROUP_ID=$(jq -r ".\"${DATABASE_STACK_NAME}\".RedisSecurityGroupId" ./outputs.json)
else
    echo "Deployment failed"
fi

cd ..

cd litellm-eks-cluster-node-group-cdk
echo "Installing dependencies for eks cluster node group cdk..."
npm install
echo "Deploying the eks cluster node group CDK stack..."
cdk deploy "$EKS_CLUSTER_NODE_GROUP_STACK_NAME" \
--context architecture=$ARCH \
--context vpcId=$VPC_ID \
--context eksClusterName=$EKS_CLUSTER_NAME \
--context eksOidcUrl=$EKS_OIDC_URL \
--outputs-file ./outputs.json

if [ $? -eq 0 ]; then
    echo "Deployment successful. Extracting outputs..."
    EKS_NODE_GROUP_ROLE_ARN=$(jq -r ".\"${EKS_CLUSTER_NODE_GROUP_STACK_NAME}\".EksNodeGroupRoleArn" ./outputs.json)
else
    echo "Deployment failed"
fi

cd ..

cd litellm-eks-cluster-pre-setup-cdk
echo "Installing dependencies for eks cluster pre setup cdk..."
npm install
echo "Deploying the eks cluster pre setup CDK stack..."
cdk deploy "$EKS_CLUSTER_PRE_SETUP_STACK_NAME" \
--context architecture=$ARCH \
--context vpcId=$VPC_ID \
--context eksClusterName=$EKS_CLUSTER_NAME \
--context eksOidcUrl=$EKS_OIDC_URL \
--outputs-file ./outputs.json

if [ $? -eq 0 ]; then
    echo "Deployment successful. Extracting outputs..."
else
    echo "Deployment failed"
fi

cd ..

cd litellm-cdk
echo "Installing dependencies..."
npm install
echo "Deploying the CDK stack..."

cdk deploy "$STACK_NAME" \
--context architecture=$ARCH \
--context liteLLMVersion=$LITELLM_VERSION \
--context ecrLitellmRepository=$APP_NAME \
--context ecrMiddlewareRepository=$MIDDLEWARE_APP_NAME \
--context certificateArn=$CERTIFICATE_ARN \
--context domainName=$DOMAIN_NAME \
--context oktaIssuer=$OKTA_ISSUER \
--context oktaAudience=$OKTA_AUDIENCE \
--context logBucketArn=$LOG_BUCKET_ARN \
--context openaiApiKey=$OPENAI_API_KEY \
--context azureOpenAiApiKey=$AZURE_OPENAI_API_KEY \
--context azureApiKey=$AZURE_API_KEY \
--context anthropicApiKey=$ANTHROPIC_API_KEY \
--context groqApiKey=$GROQ_API_KEY \
--context cohereApiKey=$COHERE_API_KEY \
--context coApiKey=$CO_API_KEY \
--context hfToken=$HF_TOKEN \
--context huggingfaceApiKey=$HUGGINGFACE_API_KEY \
--context databricksApiKey=$DATABRICKS_API_KEY \
--context geminiApiKey=$GEMINI_API_KEY \
--context codestralApiKey=$CODESTRAL_API_KEY \
--context mistralApiKey=$MISTRAL_API_KEY \
--context azureAiApiKey=$AZURE_AI_API_KEY \
--context nvidiaNimApiKey=$NVIDIA_NIM_API_KEY \
--context xaiApiKey=$XAI_API_KEY \
--context perplexityaiApiKey=$PERPLEXITYAI_API_KEY \
--context githubApiKey=$GITHUB_API_KEY \
--context deepseekApiKey=$DEEPSEEK_API_KEY \
--context ai21ApiKey=$AI21_API_KEY \
--context langsmithApiKey=$LANGSMITH_API_KEY \
--context langsmithProject=$LANGSMITH_PROJECT \
--context langsmithDefaultRunName=$LANGSMITH_DEFAULT_RUN_NAME \
--context deploymentPlatform=$DEPLOYMENT_PLATFORM \
--context vpcId=$VPC_ID \
--context eksClusterName=$EKS_CLUSTER_NAME \
--context rdsLitellmHostname=$RDS_LITELLM_HOSTNAME \
--context rdsLitellmSecretArn=$RDS_LITELLM_SECRET_ARN \
--context rdsMiddlewareHostname=$RDS_MIDDLEWARE_HOSTNAME \
--context rdsMiddlewareSecretArn=$RDS_MIDDLEWARE_SECRET_ARN \
--context redisHostName=$REDIS_HOST_NAME \
--context redisPort=$REDIS_PORT \
--context rdsSecurityGroupId=$RDS_SECURITY_GROUP_ID \
--context redisSecurityGroupId=$REDIS_SECURITY_GROUP_ID \
--context eksNodeGroupRoleArn=$EKS_NODE_GROUP_ROLE_ARN \
--context eksOidcUrl=$EKS_OIDC_URL \
--outputs-file ./outputs.json

if [ $? -eq 0 ]; then
    echo "Deployment successful. Extracting outputs..."
    LITELLM_ECS_CLUSTER=$(jq -r ".\"${STACK_NAME}\".LitellmEcsCluster" ./outputs.json)
    LITELLM_ECS_TASK=$(jq -r ".\"${STACK_NAME}\".LitellmEcsTask" ./outputs.json)
    SERVICE_URL=$(jq -r ".\"${STACK_NAME}\".ServiceURL" ./outputs.json)
    
    echo "ServiceURL=$SERVICE_URL" > resources.txt
    if [ "$DEPLOYMENT_PLATFORM" = "ECS" ]; then
        aws ecs update-service \
            --cluster $LITELLM_ECS_CLUSTER \
            --service $LITELLM_ECS_TASK \
            --force-new-deployment \
            --desired-count 1 \
            --no-cli-pager
    fi

    if [ "$DEPLOYMENT_PLATFORM" = "EKS" ]; then
        EKS_DEPLOYMENT_NAME=$(jq -r ".\"${STACK_NAME}\".EksDeploymentName" ./outputs.json)
        EKS_CLUSTER_NAME=$(jq -r ".\"${STACK_NAME}\".EksClusterNameMainStack" ./outputs.json)

        echo "EKS_DEPLOYMENT_NAME: $EKS_DEPLOYMENT_NAME"
        echo "EKS_CLUSTER_NAME: $EKS_CLUSTER_NAME"
        aws eks update-kubeconfig --region $aws_region --name $EKS_CLUSTER_NAME
        kubectl rollout restart deployment $EKS_DEPLOYMENT_NAME
    fi
else
    echo "Deployment failed"
fi