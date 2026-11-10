#!/bin/bash
# Lifecycle of the agent's LiteLLM virtual key.
#
#   scripts/agent-key.sh create   create the key (if the agent has no working one) and store it
#   scripts/agent-key.sh rotate   revoke the key and store a new one
#   scripts/agent-key.sh delete   revoke the key in LiteLLM
#   scripts/agent-key.sh status   show the key's limits and spend (not the key itself)
#
# Terraform runs `create` and `delete` itself (terraform_data.gateway_key),
# passing the inputs as AGENT_KEY_* environment variables; run by hand, the
# script reads them from the example's Terraform outputs (gateway_key_settings).
# The key is created with the gateway's master key, read from Secrets Manager
# on this machine, and written straight into the Secrets Manager secret behind
# the AgentCore Identity credential provider. Neither key is printed, put on a
# command line or written outside a private temporary directory removed on exit.
#
# SKIP_KEY_REVOCATION=1 makes `delete` a no-op (for a gateway that is gone or
# unreachable; the key must then be deleted in LiteLLM separately).
#
# Run it where the gateway is reachable (inside its network, or over its VPN).
# Prerequisites: Terraform, the AWS CLI, curl and jq; AWS credentials allowed
# to read the master key secret and write the agent key secret.
set -euo pipefail

EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${EXAMPLE_DIR}/terraform"

usage() { echo "Usage: $0 create|rotate|delete|status" >&2; exit 2; }
[ $# -eq 1 ] || usage
ACTION="$1"
case "$ACTION" in create | rotate | delete | status) ;; *) usage ;; esac

for tool in terraform aws curl jq; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-key.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ -n "${AGENT_KEY_REQUEST:-}" ]; then
  GATEWAY_URL="$AGENT_KEY_GATEWAY_URL"
  MASTER_KEY_SECRET_ARN="$AGENT_KEY_MASTER_KEY_SECRET_ARN"
  KEY_SECRET_ARN="$AGENT_KEY_SECRET_ARN"
  KEY_REQUEST="$AGENT_KEY_REQUEST"
  CA_FILE="${AGENT_KEY_CA_FILE:-}"
else
  SETTINGS="$(terraform -chdir="$TF_DIR" output -json gateway_key_settings 2>/dev/null)" ||
    { echo "No Terraform outputs: deploy the example first (scripts/deploy.sh)." >&2; exit 1; }
  GATEWAY_URL="$(jq -r .gateway_url <<<"$SETTINGS")"
  MASTER_KEY_SECRET_ARN="$(jq -r .master_key_secret_arn <<<"$SETTINGS")"
  KEY_SECRET_ARN="$(jq -r .key_secret_arn <<<"$SETTINGS")"
  KEY_REQUEST="$(jq -c .key_request <<<"$SETTINGS")"
  CA_FILE="$(jq -r '.ca_file // ""' <<<"$SETTINGS")"
fi
KEY_ALIAS="$(jq -r .key_alias <<<"$KEY_REQUEST")"

# Authorization headers live in files, so keys never appear in process lists.
write_auth_header() { printf 'Authorization: Bearer %s\n' "$2" >"$1"; }
master_header() {
  if [ ! -f "${WORK}/master.h" ]; then
    local mk
    mk="$(aws secretsmanager get-secret-value --secret-id "$MASTER_KEY_SECRET_ARN" --query SecretString --output text)"
    write_auth_header "${WORK}/master.h" "$mk"
  fi
  echo "${WORK}/master.h"
}

# gateway METHOD PATH HEADER_FILE [BODY]: prints the response body; fails on non-2xx.
gateway() {
  local method="$1" path="$2" header="$3" body="${4:-}" code
  local args=(-sS -m 30 -o "${WORK}/resp" -w '%{http_code}' -X "$method" -H "@${header}")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
  [ -n "$CA_FILE" ] && args+=(--cacert "$CA_FILE")
  code="$(curl "${args[@]}" "${GATEWAY_URL}${path}")" || { echo "Gateway ${GATEWAY_URL} unreachable." >&2; return 1; }
  if [ "${code:0:1}" != "2" ]; then
    echo "Gateway returned HTTP ${code} for ${method} ${path}: $(jq -c '.error.message // .detail // .' "${WORK}/resp" 2>/dev/null | head -c 300)" >&2
    return 1
  fi
  cat "${WORK}/resp"
}

# The key's LiteLLM record (hashed token, limits, spend), or nothing.
key_record() {
  gateway GET "/key/list?key_alias=$(jq -rn --arg a "$KEY_ALIAS" '$a|@uri')&return_full_object=true&size=10" "$(master_header)" |
    jq -c --arg a "$KEY_ALIAS" '[.keys[] | select(.key_alias == $a)] | first // empty'
}

stored_key_works() {
  local key
  key="$(aws secretsmanager get-secret-value --secret-id "$KEY_SECRET_ARN" --query SecretString --output text 2>/dev/null | jq -r '.api_key // empty' 2>/dev/null)" || return 1
  [ -n "$key" ] || return 1
  write_auth_header "${WORK}/agent.h" "$key"
  gateway GET /key/info "${WORK}/agent.h" >/dev/null 2>&1
}

revoke() {
  if [ -n "$(key_record)" ]; then
    gateway POST /key/delete "$(master_header)" "$(jq -cn --arg a "$KEY_ALIAS" '{key_aliases: [$a]}')" >/dev/null
    echo "Revoked LiteLLM key ${KEY_ALIAS}."
  else
    echo "No LiteLLM key ${KEY_ALIAS} to revoke."
  fi
}

generate_and_store() {
  gateway POST /key/generate "$(master_header)" "$KEY_REQUEST" >"${WORK}/generated"
  # The secret value is built from the response file by jq and handed to the
  # AWS CLI as a file, never as an argument.
  jq -c '{api_key: .key}' "${WORK}/generated" >"${WORK}/secret.json"
  rm -f "${WORK}/generated" "${WORK}/resp"
  aws secretsmanager put-secret-value --secret-id "$KEY_SECRET_ARN" \
    --secret-string "file://${WORK}/secret.json" >/dev/null
  echo "Created LiteLLM key ${KEY_ALIAS} and stored it in ${KEY_SECRET_ARN}."
}

case "$ACTION" in
  create)
    if stored_key_works; then
      echo "The agent already has a working key (${KEY_ALIAS}); nothing to do."
    elif [ -n "$(key_record)" ]; then
      echo "LiteLLM has a key ${KEY_ALIAS} but the stored copy is missing or invalid; run '$0 rotate'." >&2
      exit 1
    else
      generate_and_store
    fi
    ;;
  rotate)
    revoke
    generate_and_store
    ;;
  delete)
    if [ "${SKIP_KEY_REVOCATION:-}" = 1 ]; then
      echo "SKIP_KEY_REVOCATION=1: LiteLLM key ${KEY_ALIAS} is NOT revoked; delete it in LiteLLM." >&2
    else
      revoke
    fi
    ;;
  status)
    record="$(key_record)"
    [ -n "$record" ] || { echo "No LiteLLM key ${KEY_ALIAS}."; exit 1; }
    jq '{key_alias, models, spend, max_budget, budget_duration, budget_reset_at, rpm_limit, tpm_limit, created_at, metadata}' <<<"$record"
    ;;
esac
