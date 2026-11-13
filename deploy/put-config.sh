#!/bin/bash
# Upload the rendered LiteLLM config to its content-addressed key
# (config-<sha16>.yaml) in the foundation's config bucket. Called by Terraform
# (terraform_data.upload_config in terraform/modules/rollout/main.tf) during the
# app apply.
#
# Earlier keys are never deleted: every task-definition revision names its own
# config object, so a circuit-breaker rollback or an old task that scales out
# still loads the config it was deployed with.
#
# Inputs (environment): CONFIG_BUCKET, CONFIG_KEY, AWS_REGION, CONFIG_CONTENT.
# The config holds no secrets (those reach the tasks as Secrets Manager ARNs).
set -euo pipefail

: "${CONFIG_BUCKET:?}" "${CONFIG_KEY:?}" "${AWS_REGION:?}" "${CONFIG_CONTENT:?}"

tmp="$(mktemp "${TMPDIR:-/tmp}/litellm-config.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '%s' "$CONFIG_CONTENT" >"$tmp"

aws s3api put-object --region "$AWS_REGION" --bucket "$CONFIG_BUCKET" --key "$CONFIG_KEY" \
  --body "$tmp" --content-type application/yaml >/dev/null
echo "Uploaded s3://${CONFIG_BUCKET}/${CONFIG_KEY}"
