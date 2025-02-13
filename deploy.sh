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

# Load environment variables from .env file
source .env
export JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1

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
echo "EXISTING_EKS_CLUSTER_NAME: $EXISTING_EKS_CLUSTER_NAME"
echo "EXISTING_VPC_ID: $EXISTING_VPC_ID"
echo "DISABLE_OUTBOUND_NETWORK_ACCESS: $DISABLE_OUTBOUND_NETWORK_ACCESS"
echo "PRIVATE_LOAD_BALANCER: $PRIVATE_LOAD_BALANCER"

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

cdk deploy "$LOG_BUCKET_STACK_NAME" --require-approval never \
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
cdk deploy "$DATABASE_STACK_NAME" --require-approval never \
--context vpcId=$EXISTING_VPC_ID \
--context deploymentPlatform=$DEPLOYMENT_PLATFORM \
--context disableOutboundNetworkAccess=$DISABLE_OUTBOUND_NETWORK_ACCESS \
--outputs-file ./outputs.json

if [ $? -eq 0 ]; then
    echo "Deployment successful. Extracting outputs..."
    EXISTING_VPC_ID=$(jq -r ".\"${DATABASE_STACK_NAME}\".VpcId" ./outputs.json)
    RDS_LITELLM_HOSTNAME=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsLitellmHostname" ./outputs.json)
    RDS_LITELLM_SECRET_ARN=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsLitellmSecretArn" ./outputs.json)
    RDS_MIDDLEWARE_HOSTNAME=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsMiddlewareHostname" ./outputs.json)
    RDS_MIDDLEWARE_SECRET_ARN=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsMiddlewareSecretArn" ./outputs.json)
    REDIS_HOST_NAME=$(jq -r ".\"${DATABASE_STACK_NAME}\".RedisHostName" ./outputs.json)
    REDIS_PORT=$(jq -r ".\"${DATABASE_STACK_NAME}\".RedisPort" ./outputs.json)
    RDS_SECURITY_GROUP_ID=$(jq -r ".\"${DATABASE_STACK_NAME}\".RdsSecurityGroupId" ./outputs.json)
    REDIS_SECURITY_GROUP_ID=$(jq -r ".\"${DATABASE_STACK_NAME}\".RedisSecurityGroupId" ./outputs.json)

    if echo "$DISABLE_OUTBOUND_NETWORK_ACCESS" | grep -iq "^true$"; then
        EKS_ALB_CONTROLLER_PRIVATE_ECR_REPOSITORY_NAME=$(jq -r ".\"${DATABASE_STACK_NAME}\".EksAlbControllerPrivateEcrRepositoryName" ./outputs.json)
    fi
else
    echo "Deployment failed"
fi

cd ..

cd litellm-cdk
echo "Installing dependencies..."
npm install
echo "Deploying the CDK stack..."

cdk deploy "$STACK_NAME" --require-approval never \
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
--context vpcId=$EXISTING_VPC_ID \
--context rdsLitellmHostname=$RDS_LITELLM_HOSTNAME \
--context rdsLitellmSecretArn=$RDS_LITELLM_SECRET_ARN \
--context rdsMiddlewareHostname=$RDS_MIDDLEWARE_HOSTNAME \
--context rdsMiddlewareSecretArn=$RDS_MIDDLEWARE_SECRET_ARN \
--context redisHostName=$REDIS_HOST_NAME \
--context redisPort=$REDIS_PORT \
--context rdsSecurityGroupId=$RDS_SECURITY_GROUP_ID \
--context redisSecurityGroupId=$REDIS_SECURITY_GROUP_ID \
--context disableOutboundNetworkAccess=$DISABLE_OUTBOUND_NETWORK_ACCESS \
--context privateLoadBalancer=$PRIVATE_LOAD_BALANCER \
--outputs-file ./outputs.json

if [ "$DEPLOYMENT_PLATFORM" = "EKS" ]; then
    # Standard variables from CloudFormation outputs
    export TF_VAR_region=$aws_region
    export TF_VAR_name="genai-gateway"
    # Set create_cluster to false if EXISTING_EKS_CLUSTER_NAME is not empty, true otherwise
    if [ -n "$EXISTING_EKS_CLUSTER_NAME" ]; then
        export TF_VAR_create_cluster="false"
    else
        export TF_VAR_create_cluster="true"
    fi

    # Cluster information
    export TF_VAR_existing_cluster_name=$EXISTING_EKS_CLUSTER_NAME

    # VPC and Network
    export TF_VAR_vpc_id=$(jq -r ".\"${STACK_NAME}\".VpcId" ./outputs.json)

    # Architecture
    export TF_VAR_architecture=$ARCH

    # Bucket information
    export TF_VAR_config_bucket_arn=$(jq -r ".\"${STACK_NAME}\".ConfigBucketArn" ./outputs.json)
    export TF_VAR_config_bucket_name=$(jq -r ".\"${STACK_NAME}\".ConfigBucketName" ./outputs.json)
    export TF_VAR_log_bucket_arn=$LOG_BUCKET_ARN

    # ECR Repositories
    export TF_VAR_ecr_litellm_repository_url=$(jq -r ".\"${STACK_NAME}\".LiteLLMRepositoryUrl" ./outputs.json)
    export TF_VAR_ecr_middleware_repository_url=$(jq -r ".\"${STACK_NAME}\".MiddlewareRepositoryUrl" ./outputs.json)
    export TF_VAR_litellm_version=$LITELLM_VERSION


    MAIN_DB_SECRET_ARN=$(jq -r ".\"${STACK_NAME}\".DatabaseUrlSecretArn" ./outputs.json)
    MIDDLEWARE_DB_SECRET_ARN=$(jq -r ".\"${STACK_NAME}\".DatabaseMiddlewareUrlSecretArn" ./outputs.json)

    # Get the connection strings
    MAIN_DB_URL=$(aws secretsmanager get-secret-value \
    --secret-id "$MAIN_DB_SECRET_ARN" \
    --query 'SecretString' \
    --output text)

    MIDDLEWARE_DB_URL=$(aws secretsmanager get-secret-value \
    --secret-id "$MIDDLEWARE_DB_SECRET_ARN" \
    --query 'SecretString' \
    --output text)

    # Database and Redis URLs
    export TF_VAR_database_url=$MAIN_DB_URL
    export TF_VAR_database_middleware_url=$MIDDLEWARE_DB_URL

    export TF_VAR_redis_url=$(jq -r ".\"${STACK_NAME}\".RedisUrl" ./outputs.json)

    # Certificate and WAF
    export TF_VAR_certificate_arn=$CERTIFICATE_ARN
    export TF_VAR_wafv2_acl_arn=$(jq -r ".\"${STACK_NAME}\".WafAclArn" ./outputs.json)
    export TF_VAR_domain_name=$DOMAIN_NAME

    # Get the secret ARN from CloudFormation output
    LITELLM_MASTER_AND_SALT_KEY_SECRET_ARN=$(jq -r ".\"${STACK_NAME}\".LitellmMasterAndSaltKeySecretArn" ./outputs.json)

    # Get the secret JSON and parse out individual values
    LITELLM_MASTER_AND_SALT_KEY_SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$LITELLM_MASTER_AND_SALT_KEY_SECRET_ARN" \
    --query 'SecretString' \
    --output text)

    # Extract individual values using jq
    export TF_VAR_litellm_master_key=$(echo $LITELLM_MASTER_AND_SALT_KEY_SECRET_JSON | jq -r '.LITELLM_MASTER_KEY')
    export TF_VAR_litellm_salt_key=$(echo $LITELLM_MASTER_AND_SALT_KEY_SECRET_JSON | jq -r '.LITELLM_SALT_KEY')

    export TF_VAR_openai_api_key=$OPENAI_API_KEY
    export TF_VAR_azure_openai_api_key=$AZURE_OPENAI_API_KEY
    export TF_VAR_azure_api_key=$AZURE_API_KEY
    export TF_VAR_anthropic_api_key=$ANTHROPIC_API_KEY
    export TF_VAR_groq_api_key=$GROQ_API_KEY
    export TF_VAR_cohere_api_key=$COHERE_API_KEY
    export TF_VAR_co_api_key=$CO_API_KEY
    export TF_VAR_hf_token=$HF_TOKEN
    export TF_VAR_huggingface_api_key=$HUGGINGFACE_API_KEY
    export TF_VAR_databricks_api_key=$DATABRICKS_API_KEY
    export TF_VAR_gemini_api_key=$GEMINI_API_KEY
    export TF_VAR_codestral_api_key=$CODESTRAL_API_KEY
    export TF_VAR_mistral_api_key=$MISTRAL_API_KEY
    export TF_VAR_azure_ai_api_key=$AZURE_API_KEY
    export TF_VAR_nvidia_nim_api_key=$NVIDIA_NIM_API_KEY
    export TF_VAR_xai_api_key=$XAI_API_KEY
    export TF_VAR_perplexityai_api_key=$PERPLEXITYAI_API_KEY
    export TF_VAR_github_api_key=$GITHUB_API_KEY
    export TF_VAR_deepseek_api_key=$DEEPSEEK_API_KEY
    export TF_VAR_ai21_api_key=$AI21_API_KEY

    export TF_VAR_langsmith_api_key=$LANGSMITH_API_KEY
    export TF_VAR_langsmith_project=$LANGSMITH_PROJECT
    export TF_VAR_langsmith_default_run_name=$LANGSMITH_DEFAULT_RUN_NAME


    # Okta configuration
    export TF_VAR_okta_issuer=$OKTA_ISSUER
    export TF_VAR_okta_audience=$OKTA_AUDIENCE

    export TF_VAR_db_security_group_id=$(jq -r ".\"${STACK_NAME}\".DbSecurityGroupId" ./outputs.json)
    export TF_VAR_redis_security_group_id=$(jq -r ".\"${STACK_NAME}\".RedisSecurityGroupId" ./outputs.json)

    export TF_VAR_disable_outbound_network_access=$DISABLE_OUTBOUND_NETWORK_ACCESS

    if echo "$DISABLE_OUTBOUND_NETWORK_ACCESS" | grep -iq "^true$"; then
        export TF_VAR_eks_alb_controller_private_ecr_repository_name=$EKS_ALB_CONTROLLER_PRIVATE_ECR_REPOSITORY_NAME
    fi

    cd ..
    cd litellm-eks-terraform
    terraform init
    #terraform destroy -auto-approve
    terraform apply -auto-approve

fi

if [ $? -eq 0 ]; then
    echo "Deployment successful. Extracting outputs..."
    
    if [ "$DEPLOYMENT_PLATFORM" = "ECS" ]; then
        LITELLM_ECS_CLUSTER=$(jq -r ".\"${STACK_NAME}\".LitellmEcsCluster" ./outputs.json)
        LITELLM_ECS_TASK=$(jq -r ".\"${STACK_NAME}\".LitellmEcsTask" ./outputs.json)
        SERVICE_URL=$(jq -r ".\"${STACK_NAME}\".ServiceURL" ./outputs.json)
        
        echo "ServiceURL=$SERVICE_URL" > resources.txt
        aws ecs update-service \
            --cluster $LITELLM_ECS_CLUSTER \
            --service $LITELLM_ECS_TASK \
            --force-new-deployment \
            --desired-count 1 \
            --no-cli-pager
    fi

    if [ "$DEPLOYMENT_PLATFORM" = "EKS" ]; then
        EKS_CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
        EKS_DEPLOYMENT_NAME=$(terraform output -raw eks_deployment_name)

        echo "EKS_DEPLOYMENT_NAME: $EKS_DEPLOYMENT_NAME"
        echo "EKS_CLUSTER_NAME: $EKS_CLUSTER_NAME"
        aws eks update-kubeconfig --region $aws_region --name $EKS_CLUSTER_NAME
        kubectl rollout restart deployment $EKS_DEPLOYMENT_NAME
    fi
else
    echo "Deployment failed"
fi