#!/bin/bash
# Deploy or update the agent: build the code bundle and apply the Terraform
# (which also creates the agent's LiteLLM virtual key, see agent-key.sh).
#
#   AWS_REGION=<gateway region> scripts/deploy.sh [--auto-approve]
#
# Inputs: terraform/terraform.tfvars (copy terraform.tfvars.example). Run it
# where the gateway is reachable (the key is created through its API).
# Prerequisites: Terraform >= 1.11, the AWS CLI, python3 with pip, zip, curl, jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPROVE=()
for arg in "$@"; do
  case "$arg" in
    --auto-approve) APPROVE=(-auto-approve) ;;
    *) echo "Usage: $0 [--auto-approve]" >&2; exit 2 ;;
  esac
done

source "${SCRIPT_DIR}/tf-init.sh"
"${SCRIPT_DIR}/build.sh"
terraform -chdir="$TF_DIR" apply -input=false -var-file="$TFVARS" ${APPROVE[@]+"${APPROVE[@]}"}
terraform -chdir="$TF_DIR" output -json | jq '{agent_runtime_arn: .agent_runtime_arn.value, agent_runtime_id: .agent_runtime_id.value}'
