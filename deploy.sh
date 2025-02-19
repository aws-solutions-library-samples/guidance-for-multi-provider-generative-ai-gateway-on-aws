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

aws_region=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
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
LOG_BUCKET_STACK_NAME="log-bucket-stack"
MAIN_STACK_NAME="litellm-stack"

# Load environment variables from .env file
source .env

# Check if bucket exists
if aws s3api head-bucket --bucket "$TERRAFORM_S3_BUCKET_NAME" 2>/dev/null; then
    echo "Terraform Bucket $TERRAFORM_S3_BUCKET_NAME already exists, skipping creation"
else
    echo "Creating bucket $TERRAFORM_S3_BUCKET_NAME..."
    aws s3 mb "s3://$TERRAFORM_S3_BUCKET_NAME" --region $aws_region
    echo "Terraform Bucket created successfully"
fi

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
echo "HOSTED_ZONE_NAME: $HOSTED_ZONE_NAME"
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
echo "CREATE_VPC_ENDPOINTS_IN_EXISTING_VPC: $CREATE_VPC_ENDPOINTS_IN_EXISTING_VPC"
echo "INSTALL_ADD_ONS_IN_EXISTING_EKS_CLUSTER: $INSTALL_ADD_ONS_IN_EXISTING_EKS_CLUSTER"
echo "DESIRED_CAPACITY: $DESIRED_CAPACITY"
echo "MIN_CAPACITY: $MIN_CAPACITY"
echo "MAX_CAPACITY: $MAX_CAPACITY"
echo "ECS_CPU_TARGET_UTILIZATION_PERCENTAGE: $ECS_CPU_TARGET_UTILIZATION_PERCENTAGE"
echo "ECS_MEMORY_TARGET_UTILIZATION_PERCENTAGE: $ECS_MEMORY_TARGET_UTILIZATION_PERCENTAGE"
echo "ECS_VCPUS: $ECS_VCPUS"
echo "EKS_ARM_INSTANCE_TYPE: $EKS_ARM_INSTANCE_TYPE"
echo "EKS_X86_INSTANCE_TYPE: $EKS_X86_INSTANCE_TYPE"
echo "EKS_ARM_AMI_TYPE: $EKS_ARM_AMI_TYPE"
echo "EKS_X86_AMI_TYPE: $EKS_X86_AMI_TYPE"
echo "PUBLIC_LOAD_BALANCER: $PUBLIC_LOAD_BALANCER"

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

if [ "$SKIP_BUILD" = false ]; then
    echo "Building and pushing docker image..."
    #./docker-build-and-deploy.sh $APP_NAME $BUILD_FROM_SOURCE $ARCH
else
    echo "Skipping docker build and deploy step..."
fi

cd middleware
#./docker-build-and-deploy.sh $MIDDLEWARE_APP_NAME $ARCH
cd ..

echo "Deploying the log bucket terraform stack..."
cd litellm-s3-log-bucket-terraform

export TF_VAR_name=$LOG_BUCKET_STACK_NAME

cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-log-bucket.tfstate"
region  = "${aws_region}"
encrypt = true
EOF
echo "Generated backend.hcl configuration"

terraform init -backend-config=backend.hcl
terraform apply -auto-approve

if [ $? -eq 0 ]; then
    echo "Log Bucket Deployment successful. Extracting outputs..."
    LOG_BUCKET_NAME=$(terraform output -raw LogBucketName)
    LOG_BUCKET_ARN=$(terraform output -raw LogBucketArn)

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

echo "Deploying litellm-terraform-stack"
cd litellm-terraform-stack

export TF_VAR_deployment_platform=$DEPLOYMENT_PLATFORM
export TF_VAR_name=$MAIN_STACK_NAME
export TF_VAR_vpc_id=$EXISTING_VPC_ID
export TF_VAR_log_bucket_arn=$LOG_BUCKET_ARN
export TF_VAR_litellm_version=$LITELLM_VERSION
export TF_VAR_openai_api_key=$OPENAI_API_KEY
export TF_VAR_azure_openai_api_key=$AZURE_OPENAI_API_KEY
export TF_VAR_azure_api_key=$AZURE_API_KEY
export TF_VAR_anthropic_api_key=$ANTHROPIC_API_KEY
export TF_VAR_public_load_balancer=$PUBLIC_LOAD_BALANCER
export TF_VAR_existing_cluster_name=$EXISTING_EKS_CLUSTER_NAME
export TF_VAR_groq_api_key=$GROQ_API_KEY
export TF_VAR_cohere_api_key=$COHERE_API_KEY
export TF_VAR_co_api_key=$CO_API_KEY
export TF_VAR_hf_token=$HF_TOKEN
export TF_VAR_huggingface_api_key=$HUGGINGFACE_API_KEY
export TF_VAR_databricks_api_key=$DATABRICKS_API_KEY
export TF_VAR_gemini_api_key=$GEMINI_API_KEY
export TF_VAR_codestral_api_key=$CODESTRAL_API_KEY
export TF_VAR_mistral_api_key=$MISTRAL_API_KEY
export TF_VAR_azure_ai_api_key=$AZURE_AI_API_KEY
export TF_VAR_nvidia_nim_api_key=$NVIDIA_NIM_API_KEY
export TF_VAR_xai_api_key=$XAI_API_KEY
export TF_VAR_perplexityai_api_key=$PERPLEXITYAI_API_KEY
export TF_VAR_github_api_key=$GITHUB_API_KEY
export TF_VAR_deepseek_api_key=$DEEPSEEK_API_KEY
export TF_VAR_ai21_api_key=$AI21_API_KEY
export TF_VAR_langsmith_api_key=$LANGSMITH_API_KEY
export TF_VAR_langsmith_project=$LANGSMITH_PROJECT
export TF_VAR_langsmith_default_run_name=$LANGSMITH_DEFAULT_RUN_NAME
export TF_VAR_okta_audience=$OKTA_AUDIENCE
export TF_VAR_okta_issuer=$OKTA_ISSUER
export TF_VAR_domain_name=$DOMAIN_NAME
export TF_VAR_hosted_zone_name=$HOSTED_ZONE_NAME
export TF_VAR_certificate_arn=$CERTIFICATE_ARN
export TF_VAR_architecture=$ARCH
export TF_VAR_disable_outbound_network_access=$DISABLE_OUTBOUND_NETWORK_ACCESS
export TF_VAR_desired_capacity=$DESIRED_CAPACITY
export TF_VAR_min_capacity=$MIN_CAPACITY
export TF_VAR_max_capacity=$MAX_CAPACITY
export TF_VAR_cpu_target_utilization_percent=$ECS_CPU_TARGET_UTILIZATION_PERCENTAGE
export TF_VAR_memory_target_utilization_percent=$ECS_MEMORY_TARGET_UTILIZATION_PERCENTAGE
export TF_VAR_vcpus=$ECS_VCPUS
export TF_VAR_install_add_ons_in_existing_eks_cluster=$INSTALL_ADD_ONS_IN_EXISTING_EKS_CLUSTER
export TF_VAR_arm_instance_type=$EKS_ARM_INSTANCE_TYPE
export TF_VAR_x86_instance_type=$EKS_X86_INSTANCE_TYPE
export TF_VAR_arm_ami_type=$EKS_ARM_AMI_TYPE
export TF_VAR_x86_ami_type=$EKS_X86_AMI_TYPE
export TF_VAR_create_vpc_endpoints_in_existing_vpc=$CREATE_VPC_ENDPOINTS_IN_EXISTING_VPC
export TF_VAR_ecrLitellmRepository=$APP_NAME
export TF_VAR_ecrMiddlewareRepository=$MIDDLEWARE_APP_NAME

if [ -n "$EXISTING_EKS_CLUSTER_NAME" ]; then
    export TF_VAR_create_cluster="false"
else
    export TF_VAR_create_cluster="true"
fi

cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-unified.tfstate"
region  = "${aws_region}"
encrypt = true
EOF
echo "Generated backend.hcl configuration"

terraform init -backend-config=backend.hcl
terraform apply -auto-approve

if [ $? -eq 0 ]; then
    echo "Deployment successful. Extracting outputs..."
    
    if [ "$DEPLOYMENT_PLATFORM" = "ECS" ]; then

        LITELLM_ECS_CLUSTER=$(terraform output -raw LitellmEcsCluster)
        LITELLM_ECS_TASK=$(terraform output -raw LitellmEcsTask)
        SERVICE_URL=$(terraform output -raw ServiceURL)

        echo "ServiceURL=$SERVICE_URL" > resources.txt
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

        echo "EKS_DEPLOYMENT_NAME: $EKS_DEPLOYMENT_NAME"
        echo "EKS_CLUSTER_NAME: $EKS_CLUSTER_NAME"
        aws eks update-kubeconfig --region $aws_region --name $EKS_CLUSTER_NAME
        kubectl rollout restart deployment $EKS_DEPLOYMENT_NAME
    fi
else
    echo "Deployment failed"
fi