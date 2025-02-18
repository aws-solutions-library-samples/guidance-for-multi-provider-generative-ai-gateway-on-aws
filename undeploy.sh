#!/bin/bash
set -aeuo pipefail

# Parse command line arguments
if [ ! -f "config/config.yaml" ]; then
    echo "config/config.yaml does not exist, aborting"
    exit 1
fi

if [ ! -f ".env" ]; then
    echo "Error: .env file missing, aborting."
    exit 1
fi

aws_region=$(aws configure get region)
echo $aws_region

APP_NAME=litellm
MIDDLEWARE_APP_NAME=middleware
STACK_NAME="litellm-stack"
LOG_BUCKET_STACK_NAME="log-bucket-stack"
DATABASE_STACK_NAME="litellm-database-stack"

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
echo "HOSTED_ZONE_NAME: $HOSTED_ZONE_NAME"
echo "OKTA_ISSUER: $OKTA_ISSUER"
echo "OKTA_AUDIENCE: $OKTA_AUDIENCE"
echo "LiteLLM Version: " $LITELLM_VERSION
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
echo "CREATE_AWS_AUTH_IN_EXISTING_EKS_CLUSTER: $CREATE_AWS_AUTH_IN_EXISTING_EKS_CLUSTER"
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

cd litellm-s3-log-bucket-terraform
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

cd ..

# Check if required environment variables exist and are not empty
if [ -n "${LANGSMITH_API_KEY}" ] && [ -n "${LANGSMITH_PROJECT}" ] && [ -n "${LANGSMITH_DEFAULT_RUN_NAME}" ]; then

    # Update the success callback array, creating them if they don't exist
    yq eval '.litellm_settings.success_callback = ((.litellm_settings.success_callback // []) + ["langsmith"] | unique)' -i config/config.yaml

    echo "Updated config.yaml with 'langsmith' added to success callback array"
fi

cd litellm-database-terraform

RDS_LITELLM_HOSTNAME=$(terraform output -raw RdsLitellmHostname)
RDS_LITELLM_SECRET_ARN=$(terraform output -raw RdsLitellmSecretArn)
RDS_MIDDLEWARE_HOSTNAME=$(terraform output -raw RdsMiddlewareHostname)
RDS_MIDDLEWARE_SECRET_ARN=$(terraform output -raw RdsMiddlewareSecretArn)
REDIS_HOST_NAME=$(terraform output -raw RedisHostName)
REDIS_PORT=$(terraform output -raw RedisPort)
RDS_SECURITY_GROUP_ID=$(terraform output -raw RdsSecurityGroupId)
REDIS_SECURITY_GROUP_ID=$(terraform output -raw RedisSecurityGroupId)
EXISTING_VPC_ID=$(terraform output -raw VpcId)
PRIVATE_SUBNETS=$(terraform output -raw private_subnet_ids)
PUBLIC_SUBNETS=$(terraform output -raw public_subnet_ids)

cd ..

cd litellm-terraform
export TF_VAR_region=$aws_region
export TF_VAR_name="genai-gateway"

# VPC and Network
export TF_VAR_vpc_id=$(terraform output -raw VpcId)

# Architecture
export TF_VAR_architecture=$ARCH

# Bucket information
export TF_VAR_config_bucket_arn=$(terraform output -raw ConfigBucketArn)
export TF_VAR_config_bucket_name=$(terraform output -raw ConfigBucketName)
export TF_VAR_log_bucket_arn=$LOG_BUCKET_ARN

# ECR Repositories
export TF_VAR_ecr_litellm_repository_url=$(terraform output -raw LiteLLMRepositoryUrl)
export TF_VAR_ecr_middleware_repository_url=$(terraform output -raw MiddlewareRepositoryUrl)
export TF_VAR_litellm_version=$LITELLM_VERSION

MAIN_DB_SECRET_ARN=$(terraform output -raw DatabaseUrlSecretArn)
MIDDLEWARE_DB_SECRET_ARN=$(terraform output -raw DatabaseMiddlewareUrlSecretArn)

export TF_VAR_main_db_secret_arn=$MAIN_DB_SECRET_ARN
export TF_VAR_middleware_db_secret_arn=$MIDDLEWARE_DB_SECRET_ARN

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
export TF_VAR_database_url=$(aws secretsmanager get-secret-value \
    --secret-id "$MAIN_DB_SECRET_ARN" \
    --query 'SecretString' \
    --output text)
export TF_VAR_database_middleware_url=$(aws secretsmanager get-secret-value \
    --secret-id "$MIDDLEWARE_DB_SECRET_ARN" \
    --query 'SecretString' \
    --output text)

export TF_VAR_redis_url=$(terraform output -raw RedisUrl)

# Certificate and WAF
export TF_VAR_certificate_arn=$CERTIFICATE_ARN
export TF_VAR_wafv2_acl_arn=$(terraform output -raw WafAclArn)
export TF_VAR_domain_name=$DOMAIN_NAME
export TF_VAR_hosted_zone_name=$HOSTED_ZONE_NAME

# Get the secret ARN from CloudFormation output
LITELLM_MASTER_AND_SALT_KEY_SECRET_ARN=$(terraform output -raw LitellmMasterAndSaltKeySecretArn)
export TF_VAR_master_and_salt_key_secret_arn=$LITELLM_MASTER_AND_SALT_KEY_SECRET_ARN

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

export TF_VAR_db_security_group_id=$(terraform output -raw DbSecurityGroupId)
export TF_VAR_redis_security_group_id=$(terraform output -raw RedisSecurityGroupId)

export TF_VAR_disable_outbound_network_access=$DISABLE_OUTBOUND_NETWORK_ACCESS

export TF_VAR_desired_capacity=$DESIRED_CAPACITY
export TF_VAR_min_capacity=$MIN_CAPACITY
export TF_VAR_max_capacity=$MAX_CAPACITY
export TF_VAR_public_load_balancer=$PUBLIC_LOAD_BALANCER
export TF_VAR_deployment_platform=$DEPLOYMENT_PLATFORM
export TF_VAR_create_vpc_endpoints_in_existing_vpc=$CREATE_VPC_ENDPOINTS_IN_EXISTING_VPC

if [ "$DEPLOYMENT_PLATFORM" = "EKS" ]; then
    
    # Set create_cluster to false if EXISTING_EKS_CLUSTER_NAME is not empty, true otherwise
    if [ -n "$EXISTING_EKS_CLUSTER_NAME" ]; then
        export TF_VAR_create_cluster="false"
    else
        export TF_VAR_create_cluster="true"
    fi

    # Cluster information
    export TF_VAR_existing_cluster_name=$EXISTING_EKS_CLUSTER_NAME

    if echo "$DISABLE_OUTBOUND_NETWORK_ACCESS" | grep -iq "^true$"; then
        export TF_VAR_eks_alb_controller_private_ecr_repository_name=$EKS_ALB_CONTROLLER_PRIVATE_ECR_REPOSITORY_NAME
    fi

    export TF_VAR_install_add_ons_in_existing_eks_cluster=$INSTALL_ADD_ONS_IN_EXISTING_EKS_CLUSTER
    export TF_VAR_create_aws_auth_in_existing_eks_cluster=$CREATE_AWS_AUTH_IN_EXISTING_EKS_CLUSTER

    export TF_VAR_arm_instance_type=$EKS_ARM_INSTANCE_TYPE
    export TF_VAR_x86_instance_type=$EKS_X86_INSTANCE_TYPE
    export TF_VAR_arm_ami_type=$EKS_ARM_AMI_TYPE
    export TF_VAR_x86_ami_type=$EKS_X86_AMI_TYPE

    cd ../litellm-eks-terraform-roles
    DEVELOPERS_ROLE_ARN=$(terraform output -raw developers_role_arn)
    OPERATORS_ROLE_ARN=$(terraform output -raw operators_role_arn)
    NODEGROUP_ROLE_ARN=$(terraform output -raw nodegroup_role_arn)
    export TF_VAR_developers_role_arn=$DEVELOPERS_ROLE_ARN
    export TF_VAR_operators_role_arn=$OPERATORS_ROLE_ARN
    export TF_VAR_nodegroup_role_arn=$NODEGROUP_ROLE_ARN

    echo "Undeploying the litellm-eks-terraform"
    cd ../litellm-eks-terraform
    # Generate backend.hcl
    cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-main.tfstate"
region  = "${aws_region}"
encrypt = true
EOF

    echo "Generated backend.hcl configuration"
    terraform init -backend-config=backend.hcl
    terraform destroy -auto-approve
    
    echo "Undeploying the litellm-eks-terraform-roles"
    cd ../litellm-eks-terraform-roles
    cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-roles.tfstate"
region  = "${aws_region}"
encrypt = true
EOF
    terraform init -backend-config=backend.hcl
    terraform destroy -auto-approve

    cd ..
fi

if [ "$DEPLOYMENT_PLATFORM" = "ECS" ]; then
    export TF_VAR_vcpus=$ECS_VCPUS
    export TF_VAR_cpu_target_utilization_percent=$ECS_CPU_TARGET_UTILIZATION_PERCENTAGE
    export TF_VAR_memory_target_utilization_percent=$ECS_MEMORY_TARGET_UTILIZATION_PERCENTAGE
    export TF_VAR_private_subnets=$PRIVATE_SUBNETS
    export TF_VAR_public_subnets=$PUBLIC_SUBNETS

    echo "Undeploying litellm-ecs-terraform stack"
    cd ..
    cd litellm-ecs-terraform

    cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-ecs.tfstate"
region  = "${aws_region}"
encrypt = true
EOF

    echo "Generated backend.hcl configuration"
    terraform init -backend-config=backend.hcl
    terraform destroy -auto-approve
    cd ..
fi

cd litellm-terraform

export TF_VAR_region=$aws_region
export TF_VAR_stack_name=$STACK_NAME
export TF_VAR_domainName=$DOMAIN_NAME
export TF_VAR_hostedZoneName=$HOSTED_ZONE_NAME
export TF_VAR_certificateArn=$CERTIFICATE_ARN
export TF_VAR_publicLoadBalancer=$PUBLIC_LOAD_BALANCER
export TF_VAR_vpcId=$EXISTING_VPC_ID
export TF_VAR_rdsLitellmSecretArn=$RDS_LITELLM_SECRET_ARN
export TF_VAR_rdsMiddlewareSecretArn=$RDS_MIDDLEWARE_SECRET_ARN
export TF_VAR_rdsLitellmHostname=$RDS_LITELLM_HOSTNAME
export TF_VAR_rdsMiddlewareHostname=$RDS_MIDDLEWARE_HOSTNAME
export TF_VAR_rdsSecurityGroupId=$RDS_SECURITY_GROUP_ID
export TF_VAR_redisSecurityGroupId=$REDIS_SECURITY_GROUP_ID
export TF_VAR_redisHostName=$REDIS_HOST_NAME
export TF_VAR_redisPort=$REDIS_PORT
export TF_VAR_openaiApiKey=$OPENAI_API_KEY
export TF_VAR_azureOpenAiApiKey=$AZURE_OPENAI_API_KEY
export TF_VAR_azureApiKey=$AZURE_API_KEY
export TF_VAR_anthropicApiKey=$ANTHROPIC_API_KEY
export TF_VAR_groqApiKey=$GROQ_API_KEY
export TF_VAR_cohereApiKey=$COHERE_API_KEY
export TF_VAR_coApiKey=$CO_API_KEY
export TF_VAR_hfToken=$HF_TOKEN
export TF_VAR_huggingfaceApiKey=$HUGGINGFACE_API_KEY
export TF_VAR_databricksApiKey=$DATABRICKS_API_KEY
export TF_VAR_geminiApiKey=$GEMINI_API_KEY
export TF_VAR_codestralApiKey=$CODESTRAL_API_KEY
export TF_VAR_mistralApiKey=$MISTRAL_API_KEY
export TF_VAR_azureAiApiKey=$AZURE_AI_API_KEY
export TF_VAR_nvidiaNimApiKey=$NVIDIA_NIM_API_KEY
export TF_VAR_xaiApiKey=$XAI_API_KEY
export TF_VAR_perplexityaiApiKey=$PERPLEXITYAI_API_KEY
export TF_VAR_githubApiKey=$GITHUB_API_KEY
export TF_VAR_deepseekApiKey=$DEEPSEEK_API_KEY
export TF_VAR_ai21ApiKey=$AI21_API_KEY
export TF_VAR_langsmithApiKey=$LANGSMITH_API_KEY
export TF_VAR_liteLLMVersion=$LITELLM_VERSION
export TF_VAR_architecture=$ARCH
export TF_VAR_ecrLitellmRepository=$APP_NAME
export TF_VAR_ecrMiddlewareRepository=$MIDDLEWARE_APP_NAME
export TF_VAR_logBucketArn=$LOG_BUCKET_ARN
export TF_VAR_oktaIssuer=$OKTA_ISSUER
export TF_VAR_oktaAudience=$OKTA_AUDIENCE
export TF_VAR_langsmithProject=$LANGSMITH_PROJECT
export TF_VAR_langsmithDefaultRunName=$LANGSMITH_DEFAULT_RUN_NAME
export TF_VAR_deploymentPlatform=$DEPLOYMENT_PLATFORM
export TF_VAR_disableOutboundNetworkAccess=$DISABLE_OUTBOUND_NETWORK_ACCESS
export TF_VAR_desiredCapacity=$DESIRED_CAPACITY
export TF_VAR_minCapacity=$MIN_CAPACITY
export TF_VAR_maxCapacity=$MAX_CAPACITY
export TF_VAR_cpuTargetUtilizationPercent=$ECS_CPU_TARGET_UTILIZATION_PERCENTAGE
export TF_VAR_memoryTargetUtilizationPercent=$ECS_MEMORY_TARGET_UTILIZATION_PERCENTAGE
export TF_VAR_vcpus=$ECS_VCPUS

cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-litellm.tfstate"
region  = "${aws_region}"
encrypt = true
EOF
echo "Generated backend.hcl configuration"

terraform init -backend-config=backend.hcl
terraform destroy -auto-approve

if [ $? -eq 0 ]; then
    echo "Undeployment successful"
else
    echo "Undeployment failed"
fi

cd ../litellm-database-terraform
echo "Undeploying the litellm-database-terraform stack..."
export TF_VAR_stack_name=$DATABASE_STACK_NAME

cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-databases.tfstate"
region  = "${aws_region}"
encrypt = true
EOF
echo "Generated backend.hcl configuration"

terraform init -backend-config=backend.hcl
terraform destroy -auto-approve

if [ $? -eq 0 ]; then
    echo "Undeployment successful"
else
    echo "Undeployment failed"
fi

cd ..

cd litellm-s3-log-bucket-terraform

cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-log-bucket.tfstate"
region  = "${aws_region}"
encrypt = true
EOF
echo "Generated backend.hcl configuration"

terraform init -backend-config=backend.hcl
terraform destroy -auto-approve

if [ $? -eq 0 ]; then
    echo "Undeployment successful"
else
    echo "Undeployment failed"
fi

# Function to safely delete a repository
delete_repo() {
    local repo_name=$1
    
    # Check if repository exists
    if aws ecr describe-repositories --repository-names "$repo_name" 2>/dev/null; then
        # Delete all images if repository exists
        aws ecr list-images --repository-name "$repo_name" --query 'imageIds[*]' --output json 2>/dev/null | \
        aws ecr batch-delete-image --repository-name "$repo_name" --image-ids file:///dev/stdin 2>/dev/null || true
        
        # Delete the repository
        aws ecr delete-repository --repository-name "$repo_name" --force
        echo "Repository $repo_name deleted successfully"
    else
        echo "Repository $repo_name does not exist, skipping"
    fi
}

# # Delete both repositories
delete_repo "$APP_NAME"
delete_repo "$MIDDLEWARE_APP_NAME"