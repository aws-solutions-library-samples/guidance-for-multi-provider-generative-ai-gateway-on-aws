#!/bin/bash
# Operate the locust driver in the VPC through SSM Run Command.
#
#   driver.sh run <run-name> [KEY=VALUE ...]   start a run in the background
#   driver.sh status <run-name>                running | done (exit status)
#   driver.sh fetch <run-name>                 copy results to loadtest/results/<run-name>
#   driver.sh stop                             stop every running locust
#
# KEY=VALUE pairs are scenario settings (see locust/locustfile.py and
# scripts/run-driver.sh), for example STEPS=20:300,40:300 STREAM_RATIO=0.8.
# Reads the outputs of loadtest/terraform (terraform output), so run it with
# the same AWS credentials and region that applied it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${HERE}/../terraform"
RESULTS_DIR="${HERE}/../results"

out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

send() { # <comment> <shell command>
  local id
  id="$(aws ssm send-command --instance-ids "$(out driver_instance_id)" \
    --document-name AWS-RunShellScript --comment "$1" \
    --parameters "$(jq -cn --arg c "$2" '{commands: [$c], executionTimeout: ["600"]}')" \
    --query Command.CommandId --output text)"
  aws ssm wait command-executed --command-id "$id" --instance-id "$(out driver_instance_id)" || true
  aws ssm get-command-invocation --command-id "$id" --instance-id "$(out driver_instance_id)" \
    --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
}

valid_run() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid run name: $1" >&2; exit 2; }; }

cmd="${1:-}"; shift || true
case "$cmd" in
  run)
    run="${1:?run name}"; shift; valid_run "$run"
    envs="ARTIFACTS_BUCKET=$(out artifacts_bucket) API_KEY_SECRET_ID=$(out api_key_secret_id) GATEWAY_URL=$(out gateway_url)"
    for kv in "$@"; do
      [[ "$kv" =~ ^[A-Z_]+=[A-Za-z0-9.,:/_-]*$ ]] || { echo "invalid setting: $kv" >&2; exit 2; }
      envs+=" $kv"
    done
    bucket="$(out artifacts_bucket)"
    send "load test ${run}" "aws s3 cp --quiet s3://${bucket}/scenario/run-driver.sh /opt/loadtest/run-driver.sh && mkdir -p /opt/loadtest/logs && (nohup env ${envs} bash /opt/loadtest/run-driver.sh ${run} >/opt/loadtest/logs/${run}.log 2>&1 &) && echo started ${run}"
    ;;
  status)
    run="${1:?run name}"; valid_run "$run"
    if done="$(aws s3 cp --quiet "s3://$(out artifacts_bucket)/results/${run}/DONE" - 2>/dev/null)"; then
      echo "done (exit status ${done})"
    else
      echo running
    fi
    ;;
  fetch)
    run="${1:?run name}"; valid_run "$run"
    mkdir -p "${RESULTS_DIR}/${run}"
    aws s3 sync --quiet "s3://$(out artifacts_bucket)/results/${run}/" "${RESULTS_DIR}/${run}/"
    echo "${RESULTS_DIR}/${run}"
    ;;
  stop)
    send "stop load tests" "pkill -INT -f /opt/loadtest/venv/bin/locust; for i in \$(seq 1 30); do pgrep -f /opt/loadtest/venv/bin/locust >/dev/null || break; sleep 5; done; pkill -KILL -f /opt/loadtest/venv/bin/locust; pgrep -fl locust || echo stopped"
    ;;
  *)
    sed -n '2,13p' "$0"; exit 2 ;;
esac
