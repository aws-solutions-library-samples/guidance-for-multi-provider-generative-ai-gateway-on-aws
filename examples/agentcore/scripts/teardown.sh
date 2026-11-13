#!/bin/bash
# Remove the agent: revoke its LiteLLM virtual key, then destroy every
# resource of the example. The gateway is not touched.
#
#   AWS_REGION=<gateway region> scripts/teardown.sh [--auto-approve]
#
# Run it where the gateway is reachable, so the key is revoked in LiteLLM (with
# --skip-key-revocation it is not, and must be deleted in LiteLLM separately).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPROVE=()
REVOKE=true
for arg in "$@"; do
  case "$arg" in
    --auto-approve) APPROVE=(-auto-approve) ;;
    --skip-key-revocation) REVOKE=false ;;
    *) echo "Usage: $0 [--auto-approve] [--skip-key-revocation]" >&2; exit 2 ;;
  esac
done

source "${SCRIPT_DIR}/tf-init.sh"
# Terraform revokes the key itself (terraform_data.gateway_key) unless told not to.
[ "$REVOKE" = true ] || export SKIP_KEY_REVOCATION=1
# The bundle is only needed to evaluate the configuration; build it if absent.
[ -f "${EXAMPLE_DIR}/build/agent.zip" ] || "${SCRIPT_DIR}/build.sh"
terraform -chdir="$TF_DIR" destroy -input=false -var-file="$TFVARS" ${APPROVE[@]+"${APPROVE[@]}"}
