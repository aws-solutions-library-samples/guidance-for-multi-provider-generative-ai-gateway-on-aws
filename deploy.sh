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

if [ "$SKIP_BUILD" = false ]; then
    echo "Building and pushing docker image..."
    ./docker-build-and-deploy.sh $APP_NAME $BUILD_FROM_SOURCE $ARCH
else
    echo "Skipping docker build and deploy step..."
fi

cd middleware
./docker-build-and-deploy.sh $MIDDLEWARE_APP_NAME $ARCH
cd ..

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
--context createVpcEndpointsInExistingVpc=$CREATE_VPC_ENDPOINTS_IN_EXISTING_VPC \
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
--context hostedZoneName=$HOSTED_ZONE_NAME \
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
--context desiredCapacity=$DESIRED_CAPACITY \
--context minCapacity=$MIN_CAPACITY \
--context maxCapacity=$MAX_CAPACITY \
--context cpuTargetUtilizationPercent=$ECS_CPU_TARGET_UTILIZATION_PERCENTAGE \
--context memoryTargetUtilizationPercent=$ECS_MEMORY_TARGET_UTILIZATION_PERCENTAGE \
--context vcpus=$ECS_VCPUS \
--context publicLoadBalancer=$PUBLIC_LOAD_BALANCER \
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
    export TF_VAR_database_url=$(aws secretsmanager get-secret-value \
        --secret-id "$MAIN_DB_SECRET_ARN" \
        --query 'SecretString' \
        --output text)
    export TF_VAR_database_middleware_url=$(aws secretsmanager get-secret-value \
        --secret-id "$MIDDLEWARE_DB_SECRET_ARN" \
        --query 'SecretString' \
        --output text)

    export TF_VAR_redis_url=$(jq -r ".\"${STACK_NAME}\".RedisUrl" ./outputs.json)

    # Certificate and WAF
    export TF_VAR_certificate_arn=$CERTIFICATE_ARN
    export TF_VAR_wafv2_acl_arn=$(jq -r ".\"${STACK_NAME}\".WafAclArn" ./outputs.json)
    export TF_VAR_domain_name=$DOMAIN_NAME
    export TF_VAR_hosted_zone_name=$HOSTED_ZONE_NAME

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

    export TF_VAR_install_add_ons_in_existing_eks_cluster=$INSTALL_ADD_ONS_IN_EXISTING_EKS_CLUSTER

    export TF_VAR_desired_capacity=$DESIRED_CAPACITY
    export TF_VAR_min_capacity=$MIN_CAPACITY
    export TF_VAR_max_capacity=$MAX_CAPACITY

    export TF_VAR_arm_instance_type=$EKS_ARM_INSTANCE_TYPE
    export TF_VAR_x86_instance_type=$EKS_X86_INSTANCE_TYPE
    export TF_VAR_arm_ami_type=$EKS_ARM_AMI_TYPE
    export TF_VAR_x86_ami_type=$EKS_X86_AMI_TYPE

    export TF_VAR_public_load_balancer=$PUBLIC_LOAD_BALANCER

    echo "Deploying litellm-eks-terraform-roles stack"
    cd ..
    cd litellm-eks-terraform-roles
    terraform init
    terraform apply -auto-approve
    if [ $? -eq 0 ]; then
        echo "Deployment successful. Extracting role arn outputs..."
        DEVELOPERS_ROLE_ARN=$(terraform output -raw developers_role_arn)
        OPERATORS_ROLE_ARN=$(terraform output -raw operators_role_arn)
        NODEGROUP_ROLE_ARN=$(terraform output -raw nodegroup_role_arn)
        export TF_VAR_developers_role_arn=$DEVELOPERS_ROLE_ARN
        export TF_VAR_operators_role_arn=$OPERATORS_ROLE_ARN
        export TF_VAR_nodegroup_role_arn=$NODEGROUP_ROLE_ARN
    else
        echo "Deployment failed"
    fi

    if echo "$CREATE_AWS_AUTH_IN_EXISTING_EKS_CLUSTER" | grep -iq "^false$" && [ -n "$EXISTING_EKS_CLUSTER_NAME" ]; then
        echo "Updating existing aws-auth with additional roles..."

        # Temporary files
        AWS_AUTH_YAML="$(mktemp)"
        AWS_AUTH_PARTIAL_YAML="$(mktemp)"
        CURRENT_ROLES_YAML="$(mktemp)"
        NEW_ROLES_YAML="$(mktemp)"
        AWS_AUTH_UPDATED_YAML="$(mktemp)"

        # Use a trap to clean up temp files even if the script fails
        cleanup() {
          rm -f "$AWS_AUTH_YAML" "$AWS_AUTH_PARTIAL_YAML" \
                "$CURRENT_ROLES_YAML" "$NEW_ROLES_YAML" "$AWS_AUTH_UPDATED_YAML"
        }
        trap cleanup EXIT

        # 1) Get the entire aws-auth ConfigMap
        kubectl get configmap aws-auth -n kube-system -o yaml > "$AWS_AUTH_YAML"

        # 2) Extract current mapRoles *as raw text* (important!)
        #    Without '-r', yq might parse it as a YAML sequence.
        yq e -r '.data.mapRoles' "$AWS_AUTH_YAML" > "$CURRENT_ROLES_YAML"

        # 2a) Check if any of the role ARNs already exist
        if grep -qF "$NODEGROUP_ROLE_ARN" "$CURRENT_ROLES_YAML" || \
            grep -qF "$DEVELOPERS_ROLE_ARN" "$CURRENT_ROLES_YAML" || \
            grep -qF "$OPERATORS_ROLE_ARN"  "$CURRENT_ROLES_YAML"; then
            echo "At least one of the roles already exists in aws-auth. Skipping update."
        else
            #3) Define the new roles with proper indentation
            cat <<EOF > "$NEW_ROLES_YAML"
- rolearn: ${NODEGROUP_ROLE_ARN}
  username: system:node:{{EC2PrivateDNSName}}
  groups:
    - system:bootstrappers
    - system:nodes

- rolearn: ${DEVELOPERS_ROLE_ARN}
  username: eks-developers
  groups:
    - eks-developers

- rolearn: ${OPERATORS_ROLE_ARN}
  username: eks-operators
  groups:
    - eks-operators
EOF

            # 4) Append the new roles to the existing roles (just text concatenation)
            cat "$NEW_ROLES_YAML" >> "$CURRENT_ROLES_YAML"

            # 5) Remove the old mapRoles field from the ConfigMap
            yq e 'del(.data.mapRoles)' "$AWS_AUTH_YAML" > "$AWS_AUTH_PARTIAL_YAML"

            # 6) Inject the merged roles back in as a multiline string
            #    Use strenv() to ensure the shell variable is inserted as text
            export MERGED_ROLES="$(cat "$CURRENT_ROLES_YAML")"
            yq e '.data.mapRoles = strenv(MERGED_ROLES)' \
                "$AWS_AUTH_PARTIAL_YAML" \
                > "$AWS_AUTH_UPDATED_YAML"

            # 7) Apply the updated ConfigMap
            kubectl apply -f "$AWS_AUTH_UPDATED_YAML"

            echo "Successfully updated aws-auth with additional roles."
        fi
    fi

    export TF_VAR_create_aws_auth_in_existing_eks_cluster=$CREATE_AWS_AUTH_IN_EXISTING_EKS_CLUSTER

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