#!/bin/bash
# Deploy or update the gateway: the foundation root module first, then app.
#
#   deploy/deploy.sh [--auto-approve]
#
# Inputs come from deploy/terraform.tfvars (copy terraform.tfvars.example; it
# documents every variable and which root module consumes it). A relative
# config_override_file is read from deploy/, next to terraform.tfvars. Each plan is
# shown for review and applied only after confirmation; --auto-approve skips
# the review. Foundation outputs are wired into app via `terraform output
# -json` — app never reads foundation state directly.
#
# State lives in a versioned, encrypted, private S3 bucket with native S3
# locking, under <deployment_name>/foundation.tfstate and
# <deployment_name>/app.tfstate. The bucket is created on first run (the
# fresh-account bootstrap step, see docs/deployment.md) and must be
# owned by the deploying account; override its name with TF_STATE_BUCKET, the
# region with AWS_REGION.
#
# Prerequisites: Terraform >= 1.11, the AWS CLI and jq.
# Nothing secret is read from or printed by this script: secrets enter the
# stack as Secrets Manager ARNs only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
FOUNDATION_DIR="${REPO_ROOT}/terraform/foundation"
APP_DIR="${REPO_ROOT}/terraform/app"
TFVARS="${SCRIPT_DIR}/terraform.tfvars"
GEN_DIR="${SCRIPT_DIR}/.generated"

usage() {
  cat <<USAGE
Usage: $0 [--auto-approve]

Deploys or updates the gateway from deploy/terraform.tfvars: the foundation
root module first, then app. Each plan is shown and applied only after you
type 'yes'.

  --auto-approve  apply the plans without asking
  -h, --help      show this help
USAGE
}

AUTO_APPROVE=false
for arg in "$@"; do
  case "$arg" in
    --auto-approve) AUTO_APPROVE=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for tool in terraform aws jq; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
[ -f "$TFVARS" ] || { echo "Missing ${TFVARS} (copy terraform.tfvars.example and edit it)" >&2; exit 1; }

# deployment_name from the tfvars, parsed by Terraform itself (no regex over
# HCL). It keys the state objects and the generated outputs file, so two
# deployments in one account and region never share state.
read_deployment_name() {
  local tmp name
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tfvars-name.XXXXXX")"
  printf 'variable "deployment_name" {\n  type    = string\n  default = ""\n}\n' >"${tmp}/main.tf"
  name="$(echo 'var.deployment_name' | terraform -chdir="$tmp" console -var-file="$TFVARS" 2>/dev/null |
    sed -n 's/^"\([a-z][a-z0-9-]*\)"$/\1/p' | tail -n 1)" || true
  rm -rf "$tmp"
  [[ "$name" =~ ^[a-z][a-z0-9-]{0,19}$ ]] ||
    { echo "deployment_name is missing or invalid in ${TFVARS}" >&2; exit 1; }
  printf '%s\n' "$name"
}
DEPLOYMENT_NAME="$(read_deployment_name)"

# One value from the tfvars, parsed by Terraform itself (no regex over HCL);
# base64 keeps quotes and backslashes in the value intact. Prints the raw
# value, or nothing when it is null or unset.
read_tfvar() { # name type default-hcl
  local tmp out
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tfvars-read.XXXXXX")"
  printf 'variable "%s" {\n  type    = %s\n  default = %s\n}\n' "$1" "$2" "$3" >"${tmp}/main.tf"
  out="$(echo "var.$1 == null ? \"\" : base64encode(tostring(var.$1))" |
    terraform -chdir="$tmp" console -var-file="$TFVARS" 2>/dev/null | tail -n 1)" || true
  rm -rf "$tmp"
  [[ "$out" =~ ^\"([A-Za-z0-9+/=]*)\"$ ]] ||
    { echo "Could not read $1 from ${TFVARS} (check the file with terraform validate)" >&2; return 1; }
  printf '%s' "${BASH_REMATCH[1]}" | base64 --decode
}

# config_override_file is written next to terraform.tfvars, but Terraform
# resolves a relative path from the root module directory. Resolve it against
# deploy/ here and hand the absolute path to the app via -var.
resolve_config_override() { # -> absolute path, or nothing when unset
  local path dir
  path="$(read_tfvar config_override_file string 'null')" || return 1
  [ -n "$path" ] || return 0
  case "$path" in
    /*) ;;
    \~/*) path="${HOME}/${path#\~/}" ;;
    *) path="${SCRIPT_DIR}/${path}" ;;
  esac
  [ -f "$path" ] ||
    { echo "config_override_file not found: ${path} (a relative path is read from ${SCRIPT_DIR})" >&2; return 1; }
  dir="$(cd "$(dirname "$path")" && pwd)"
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}
CONFIG_OVERRIDE_FILE="$(resolve_config_override)"

REGION="${AWS_REGION:-$(aws configure get region || true)}"
[ -n "$REGION" ] || { echo "No region: set AWS_REGION or configure a default region" >&2; exit 1; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-litellm-gateway-tfstate-${ACCOUNT_ID}-${REGION}}"

# Succeeds only when the bucket exists AND belongs to this account; a bucket of
# the same name owned by another account is rejected, never written to.
state_bucket_status() { # -> owned | missing | foreign
  local err
  if err="$(aws s3api head-bucket --bucket "$TF_STATE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" 2>&1 >/dev/null)"; then
    echo owned
  elif [[ "$err" == *"Not Found"* || "$err" == *"404"* ]]; then
    echo missing
  else
    echo foreign
  fi
}

# State bucket: versioned, encrypted, private, owner-enforced, TLS-only, with
# native S3 state locking (use_lockfile). Creating it is the fresh-account
# bootstrap step.
case "$(state_bucket_status)" in
  owned) echo "Using Terraform state bucket ${TF_STATE_BUCKET}" ;;
  foreign)
    echo "State bucket ${TF_STATE_BUCKET} exists but is not owned by account ${ACCOUNT_ID} (or is not accessible): refusing to use it." >&2
    exit 1 ;;
  missing)
  echo "Creating Terraform state bucket ${TF_STATE_BUCKET} in ${REGION}"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "$TF_STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$TF_STATE_BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$TF_STATE_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-ownership-controls --bucket "$TF_STATE_BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
  aws s3api put-bucket-policy --bucket "$TF_STATE_BUCKET" --policy "$(jq -cn --arg b "$TF_STATE_BUCKET" '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "DenyInsecureTransport", Effect: "Deny", Principal: "*", Action: "s3:*",
      Resource: ["arn:aws:s3:::\($b)", "arn:aws:s3:::\($b)/*"],
      Condition: { Bool: { "aws:SecureTransport": "false" } }
    }]
  }')"
  ;;
esac

init() { # dir state-key
  terraform -chdir="$1" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=$2" \
    -backend-config="region=${REGION}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true" >/dev/null
}

# Plan files hold the planned values: removed on every exit path, including
# a failed plan or apply.
CURRENT_PLAN=""
cleanup_plan() { [ -z "$CURRENT_PLAN" ] || rm -f "$CURRENT_PLAN"; }
trap cleanup_plan EXIT

plan_and_apply() { # label dir [extra terraform plan arguments...]
  local label="$1" dir="$2" plan_file
  shift 2
  local var_files=(-var-file "$TFVARS" "$@")

  plan_file="$(mktemp "${TMPDIR:-/tmp}/${label}.tfplan.XXXXXX")"
  CURRENT_PLAN="$plan_file"
  echo ""
  echo "=== ${label}: plan ==="
  terraform -chdir="$dir" plan -input=false "${var_files[@]}" -out="$plan_file"

  if [ "$AUTO_APPROVE" != true ]; then
    local answer
    read -r -p "Apply the ${label} plan above? Only 'yes' applies: " answer
    if [ "$answer" != "yes" ]; then
      echo "Stopped: the ${label} plan was not applied." >&2
      exit 1
    fi
  fi

  echo "=== ${label}: apply ==="
  terraform -chdir="$dir" apply -input=false "$plan_file"
  rm -f "$plan_file"
  CURRENT_PLAN=""
}

export AWS_REGION="$REGION"

echo "Deployment ${DEPLOYMENT_NAME}: state under s3://${TF_STATE_BUCKET}/${DEPLOYMENT_NAME}/"
init "$FOUNDATION_DIR" "${DEPLOYMENT_NAME}/foundation.tfstate"
plan_and_apply "foundation" "$FOUNDATION_DIR"

# Wire foundation outputs into app as plain input variables (names match 1:1).
# Null-valued outputs (e.g. kms_key_arn without a customer key) are omitted by
# `terraform output -json`; the matching app variables default to null. This
# file comes after terraform.tfvars on the command line, so for names both
# carry (vpc_id, subnets, vpc_cidr, kms_key_arn, ...) the foundation's actual
# values win. db_endpoint is an output for other consumers only (the app
# reaches the database through the DATABASE_URL secret), so it is left out.
mkdir -p "$GEN_DIR"
FOUNDATION_OUTPUTS="${GEN_DIR}/${DEPLOYMENT_NAME}-foundation-outputs.tfvars.json"
terraform -chdir="$FOUNDATION_DIR" output -json \
  | jq 'with_entries(.value |= .value) | del(.db_endpoint)' > "$FOUNDATION_OUTPUTS"

# The app apply also runs the database migration: terraform_data.migrate calls
# deploy/run-migration.sh (a one-off ECS task) and the service only rolls after
# it exits 0 — LiteLLM reports healthy on an unmigrated database, so the rollout
# must be gated on the migration's result, not on health checks.
init "$APP_DIR" "${DEPLOYMENT_NAME}/app.tfstate"
APP_ARGS=(-var-file "$FOUNDATION_OUTPUTS")
[ -z "$CONFIG_OVERRIDE_FILE" ] || APP_ARGS+=(-var "config_override_file=${CONFIG_OVERRIDE_FILE}")
plan_and_apply "app" "$APP_DIR" "${APP_ARGS[@]}"

echo ""
echo "Done. Gateway URL:"
terraform -chdir="$APP_DIR" output -raw service_url
