#!/bin/bash
# Runs ON the driver instance (started by scripts/driver.sh through SSM):
#   run-driver.sh <run-name>
# Configuration comes from the environment: ARTIFACTS_BUCKET, API_KEY_SECRET_ID,
# GATEWAY_URL (set by driver.sh) and the scenario settings of
# locust/locustfile.py (STEPS, STREAM_RATIO, ...). Without STEPS, USERS,
# SPAWN_RATE and RUN_TIME apply. PROCESSES: locust processes (default: vCPUs).
# Results are synced to s3://$ARTIFACTS_BUCKET/results/<run-name>/ every
# minute and at the end, where a DONE file marks completion.
set -euo pipefail

RUN="${1:?usage: run-driver.sh <run-name>}"
[[ "$RUN" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid run name" >&2; exit 2; }
: "${ARTIFACTS_BUCKET:?}" "${API_KEY_SECRET_ID:?}" "${GATEWAY_URL:?}"
DIR="/opt/loadtest/runs/${RUN}"
DEST="s3://${ARTIFACTS_BUCKET}/results/${RUN}/"
mkdir -p "${DIR}/results"
cd "$DIR"

if pgrep -f /opt/loadtest/venv/bin/locust >/dev/null; then
  echo "another locust run is active (driver.sh stop)" >&2; exit 1
fi
until [ -f /opt/loadtest/ready ]; do echo "waiting for bootstrap"; sleep 10; done
aws s3 cp --quiet "s3://${ARTIFACTS_BUCKET}/scenario/locustfile.py" locustfile.py

# The key is passed to locust through its environment only (not argv or logs).
API_KEY="$(aws secretsmanager get-secret-value --secret-id "$API_KEY_SECRET_ID" --query SecretString --output text)"
export API_KEY
export REQUEST_LOG_DIR="${DIR}/results"

ulimit -n 65536
sync_results() { aws s3 sync --quiet "${DIR}/results" "$DEST" || true; }
( while sleep 60; do sync_results; done ) &
SYNC_PID=$!
trap 'kill $SYNC_PID 2>/dev/null || true' EXIT

args=(-f locustfile.py --headless --only-summary -H "$GATEWAY_URL"
  --processes "${PROCESSES:-$(nproc)}" --master-bind-host 127.0.0.1 --csv results/locust --html results/report.html
  --stop-timeout 120)
if [ -z "${STEPS:-}" ]; then
  args+=(-u "${USERS:-10}" -r "${SPAWN_RATE:-5}" -t "${RUN_TIME:-5m}")
fi

set +e
/opt/loadtest/venv/bin/locust "${args[@]}" >results/locust.log 2>&1
status=$?
set -e
echo "$status" >results/DONE
sync_results
echo "run ${RUN} finished with exit status ${status}"
