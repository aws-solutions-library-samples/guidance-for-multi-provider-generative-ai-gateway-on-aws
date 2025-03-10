
#!/bin/bash
set -aeuo pipefail

aws_region=$(aws ec2 describe-availability-zones --output text --query 'AvailabilityZones[0].[RegionName]')
echo $aws_region

APP_NAME=fakeserver

source .env

cd litellm-terraform-stack
VPC_ID=$(terraform output -raw vpc_id)
cd ..

cd litellm-fake-llm-load-testing-server-terraform

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

echo "about to destroy"

export TF_VAR_vpc_id="vpc-02b681fa786fa8292"
export TF_VAR_ecr_fake_server_repository=$APP_NAME
export TF_VAR_architecture=$ARCH
export TF_VAR_fake_llm_load_testing_endpoint_certifiacte_arn=$FAKE_LLM_LOAD_TESTING_ENDPOINT_CERTIFICATE_ARN
export TF_VAR_fake_llm_load_testing_endpoint_hosted_zone_name=$FAKE_LLM_LOAD_TESTING_ENDPOINT_HOSTED_ZONE_NAME
export TF_VAR_fake_llm_load_testing_endpoint_record_name=$FAKE_LLM_LOAD_TESTING_ENDPOINT_RECORD_NAME


cat > backend.hcl << EOF
bucket  = "${TERRAFORM_S3_BUCKET_NAME}"
key     = "terraform-fake-llm-server.tfstate"
region  = "${aws_region}"
encrypt = true
EOF
echo "Generated backend.hcl configuration"

terraform init -backend-config=backend.hcl -reconfigure
terraform destroy -auto-approve

echo "destroyed"