#!/bin/bash
# Register (setup) or remove (teardown) the load-test model and virtual key on
# the gateway through the LiteLLM admin API.
#
#   GATEWAY_URL=https://gateway.example.com MASTER_KEY_SECRET_ID=<name-or-arn> gateway.sh setup
#   GATEWAY_URL=... MASTER_KEY_SECRET_ID=... gateway.sh teardown
#
# setup: adds model <prefix>-fake (api_base = the fake upstream, terraform
# output fake_api_base), plus <prefix>-fake-instant (no delays, for measuring
# gateway overhead), generates a virtual key aliased <prefix>-driver limited to
# them, and stores the key in the driver's secret (output api_key_secret_id).
# teardown: deletes every model and key whose name/alias starts with <prefix>-.
# PREFIX defaults to the terraform name_prefix. The master key is read from
# Secrets Manager into a mode-0600 curl header file, not argv or output.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${HERE}/../terraform"
: "${GATEWAY_URL:?set GATEWAY_URL (reachable from this machine)}" "${MASTER_KEY_SECRET_ID:?set MASTER_KEY_SECRET_ID}"
for tool in aws jq curl terraform; do command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }; done
PREFIX="${PREFIX:-$(terraform -chdir="$TF_DIR" output -raw name_prefix 2>/dev/null || echo llmgw-load)}"

TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
HDR="${TMP}/headers"
( umask 077
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' \
    "$(aws secretsmanager get-secret-value --secret-id "$MASTER_KEY_SECRET_ID" --query SecretString --output text)" >"$HDR" )

api() { # <method> <path> [json body]
  local code
  code="$(curl -sS -o "${TMP}/body" -w '%{http_code}' -X "$1" -H @"$HDR" ${3:+--data "$3"} "${GATEWAY_URL}$2")"
  [[ "$code" == 2* ]] || { echo "$1 $2 -> HTTP $code: $(head -c 300 "${TMP}/body")" >&2; return 1; }
  cat "${TMP}/body"
}

add_model() { # <name> <api_base>
  api POST /model/new "$(jq -cn --arg n "$1" --arg b "$2" \
    '{model_name: $n, litellm_params: {model: "openai/fake", api_base: $b, api_key: "unused"}}')" >/dev/null
  echo "model $1 -> $2"
}

case "${1:-}" in
  setup)
    base="$(terraform -chdir="$TF_DIR" output -raw fake_api_base)"
    add_model "${PREFIX}-fake" "$base"
    add_model "${PREFIX}-fake-instant" "${base%/v1}/p/0/0/20/v1"
    models="$(jq -cn --arg p "$PREFIX" '[$p + "-fake", $p + "-fake-instant"]')"
    api POST /key/generate "$(jq -cn --arg a "${PREFIX}-driver" --argjson m "$models" \
      '{key_alias: $a, models: $m, duration: "7d", metadata: {purpose: "load test"}}')" |
      jq -r .key >"${TMP}/key"
    aws secretsmanager put-secret-value --secret-id "$(terraform -chdir="$TF_DIR" output -raw api_key_secret_id)" \
      --secret-string "file://${TMP}/key" >/dev/null
    echo "key ${PREFIX}-driver stored in the driver secret"
    ;;
  teardown)
    api GET /model/info | jq -r --arg p "${PREFIX}-" '.data[] | select(.model_name | startswith($p)) | .model_info.id' |
      while read -r id; do api POST /model/delete "$(jq -cn --arg i "$id" '{id: $i}')" >/dev/null && echo "deleted model ${id}"; done
    page=1 tokens=()
    while :; do # collect first, delete after: deleting shifts the pages
      api GET "/key/list?return_full_object=true&size=100&page=${page}" >"${TMP}/keys"
      while read -r token; do tokens+=("$token"); done < <(jq -r --arg p "${PREFIX}-" \
        '.keys[] | select((.key_alias // "") | startswith($p)) | .token' "${TMP}/keys")
      [ "$page" -lt "$(jq -r '.total_pages // 1' "${TMP}/keys")" ] || break
      page=$((page + 1))
    done
    for token in ${tokens[@]+"${tokens[@]}"}; do
      api POST /key/delete "$(jq -cn --arg t "$token" '{keys: [$t]}')" >/dev/null && echo "deleted key ${token:0:8}..."
    done
    ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac
