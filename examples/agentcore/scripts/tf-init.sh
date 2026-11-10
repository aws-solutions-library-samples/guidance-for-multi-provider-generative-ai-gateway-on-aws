#!/bin/bash
# Sourced by deploy.sh and teardown.sh: initialise the example's Terraform with
# its state in the gateway deployment's state bucket, under its own key
# (examples/agentcore/<name>.tfstate), so it never shares state with the
# gateway. Override the bucket with TF_STATE_BUCKET, the region with AWS_REGION.

EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${EXAMPLE_DIR}/terraform"
TFVARS="${TF_DIR}/terraform.tfvars"

for tool in terraform aws jq; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
[ -f "$TFVARS" ] || { echo "Missing ${TFVARS} (copy terraform.tfvars.example and edit it)" >&2; exit 1; }

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[ -n "$REGION" ] || { echo "Set AWS_REGION to the gateway's region." >&2; exit 1; }
export AWS_REGION="$REGION"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-litellm-gateway-tfstate-${ACCOUNT_ID}-${REGION}}"
aws s3api head-bucket --bucket "$TF_STATE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1 || {
  echo "State bucket ${TF_STATE_BUCKET} not found or not owned by ${ACCOUNT_ID}; set TF_STATE_BUCKET." >&2
  exit 1
}

# The agent name keys the state object, so several agents can be deployed side
# by side. It is read from the tfvars by Terraform itself (no regex over HCL),
# in a scratch module declaring only that variable, with the same default.
read_agent_name() {
  local tmp name
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tfvars-name.XXXXXX")"
  printf 'variable "name" {\n  type    = string\n  default = "llmgw-agent-demo"\n}\n' >"${tmp}/main.tf"
  name="$(echo 'var.name' | terraform -chdir="$tmp" console -var-file="$TFVARS" 2>/dev/null |
    sed -n 's/^"\([a-z][a-z0-9-]*\)"$/\1/p' | tail -n 1)" || true
  rm -rf "$tmp"
  [[ "$name" =~ ^[a-z][a-z0-9-]{2,29}$ ]] || { echo "name is invalid in ${TFVARS}" >&2; exit 1; }
  printf '%s\n' "$name"
}
AGENT_NAME="$(read_agent_name)"

terraform -chdir="$TF_DIR" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=examples/agentcore/${AGENT_NAME}.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true" >/dev/null
echo "Terraform state: s3://${TF_STATE_BUCKET}/examples/agentcore/${AGENT_NAME}.tfstate"
