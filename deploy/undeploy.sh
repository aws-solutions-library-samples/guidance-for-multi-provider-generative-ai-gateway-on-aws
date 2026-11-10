#!/bin/bash
# Destroy the gateway: the app root module first, then foundation. Each destroy
# plan is shown for review and applied only after confirmation; --auto-approve
# skips the review.
#
#   deploy/undeploy.sh [--auto-approve]
#
# Deletion protection is respected, never disabled here: with
# deletion_protection = true (the default, also when unset) the script stops
# before any destroy. To remove everything, set deletion_protection = false in
# deploy/terraform.tfvars, run deploy/deploy.sh, then run this script again.
# The database always leaves a final snapshot and keeps its automated backups
# (unless destroy_data_without_snapshot = true, for throwaway deployments).
# The Terraform state bucket is always kept.
#
# Prerequisites: Terraform >= 1.11, the AWS CLI and jq.
# Nothing secret is read from or printed by this script.
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

Destroys the gateway described by deploy/terraform.tfvars: the app root module
first, then foundation. Each destroy plan is shown and applied only after you
type 'yes'. Nothing is destroyed while deletion_protection is true (the
default): set it to false and run deploy/deploy.sh first.

  --auto-approve  destroy without asking
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
[ -f "$TFVARS" ] || { echo "Missing ${TFVARS} (the same file the deploy used)" >&2; exit 1; }

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
# Refuse before any AWS call or destroy while protection is on: a destroy plan
# would otherwise take the service down before the protected resources fail.
DELETION_PROTECTION="$(read_tfvar deletion_protection bool 'true')"
if [ "$DELETION_PROTECTION" != false ]; then
  cat >&2 <<NOTE
deletion_protection is true in ${TFVARS} (the default when unset).
Nothing was destroyed.

To remove the deployment:
  1. set deletion_protection = false in ${TFVARS}
  2. run deploy/deploy.sh (it releases the protection; the database still
     leaves a final snapshot unless destroy_data_without_snapshot = true)
  3. run this script again
NOTE
  exit 1
fi

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

case "$(state_bucket_status)" in
  owned) ;;
  missing)
    echo "State bucket ${TF_STATE_BUCKET} not found: nothing to undeploy (set TF_STATE_BUCKET if it has a custom name)" >&2
    exit 1 ;;
  *)
    echo "State bucket ${TF_STATE_BUCKET} is not owned by account ${ACCOUNT_ID} (or is not accessible): refusing to use it." >&2
    exit 1 ;;
esac

init() { # dir state-key
  terraform -chdir="$1" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=$2" \
    -backend-config="region=${REGION}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true" >/dev/null
}

# Plan files hold the planned values: removed on every exit path.
CURRENT_PLAN=""
cleanup_plan() { [ -z "$CURRENT_PLAN" ] || rm -f "$CURRENT_PLAN"; }
trap cleanup_plan EXIT

plan_and_destroy() { # label dir [extra terraform plan arguments...]
  local label="$1" dir="$2" plan_file
  shift 2
  local var_files=(-var-file "$TFVARS" "$@")

  plan_file="$(mktemp "${TMPDIR:-/tmp}/${label}-destroy.tfplan.XXXXXX")"
  CURRENT_PLAN="$plan_file"
  echo ""
  echo "=== ${label}: destroy plan ==="
  terraform -chdir="$dir" plan -destroy -input=false "${var_files[@]}" -out="$plan_file"

  if [ "$AUTO_APPROVE" != true ]; then
    local answer
    read -r -p "Destroy ${label} as planned above? Only 'yes' destroys: " answer
    if [ "$answer" != "yes" ]; then
      echo "Stopped: ${label} was not destroyed." >&2
      exit 1
    fi
  fi

  echo "=== ${label}: destroy ==="
  if ! terraform -chdir="$dir" apply -input=false "$plan_file"; then
    echo "" >&2
    echo "Destroying ${label} failed. If the error mentions deletion protection:" >&2
    echo "set deletion_protection = false in ${TFVARS}, run deploy/deploy.sh," >&2
    echo "then run this script again (the database still leaves a final snapshot)." >&2
    exit 1
  fi
  rm -f "$plan_file"
  CURRENT_PLAN=""
}

export AWS_REGION="$REGION"

# App first: it is destroyable against a living foundation at any time.
echo "Deployment ${DEPLOYMENT_NAME}: state under s3://${TF_STATE_BUCKET}/${DEPLOYMENT_NAME}/"
init "$APP_DIR" "${DEPLOYMENT_NAME}/app.tfstate"
mkdir -p "$GEN_DIR"
FOUNDATION_OUTPUTS="${GEN_DIR}/${DEPLOYMENT_NAME}-foundation-outputs.tfvars.json"
init "$FOUNDATION_DIR" "${DEPLOYMENT_NAME}/foundation.tfstate"
# db_endpoint is not an app variable (see deploy.sh).
terraform -chdir="$FOUNDATION_DIR" output -json \
  | jq 'with_entries(.value |= .value) | del(.db_endpoint)' > "$FOUNDATION_OUTPUTS"
APP_ARGS=(-var-file "$FOUNDATION_OUTPUTS")
[ -z "$CONFIG_OVERRIDE_FILE" ] || APP_ARGS+=(-var "config_override_file=${CONFIG_OVERRIDE_FILE}")
plan_and_destroy "app" "$APP_DIR" "${APP_ARGS[@]}"

plan_and_destroy "foundation" "$FOUNDATION_DIR"

echo ""
echo "Done. The Terraform state bucket ${TF_STATE_BUCKET} is kept; delete it manually if wanted."
