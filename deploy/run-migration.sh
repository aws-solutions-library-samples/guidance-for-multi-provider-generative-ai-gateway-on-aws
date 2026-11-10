#!/bin/bash
# Run LiteLLM's database migration once, as a one-off ECS task, and fail if it
# fails. Called by Terraform (the rollout module, terraform/modules/rollout)
# during `terraform apply`, BEFORE the service rolls to a new task definition:
# LiteLLM's health endpoints report healthy on an unmigrated database, so
# nothing downstream would catch a missed migration.
#
# Inputs (environment): CLUSTER, TASK_DEFINITION, SUBNETS (comma-separated),
# SECURITY_GROUPS (comma-separated), AWS_REGION, and optionally
# MIGRATION_TIMEOUT_SECONDS (default 1200) and MIGRATION_POLL_SECONDS (default
# 15). Unless the task was seen STOPPED, it is stopped on every exit (timeout,
# an AWS CLI error, Ctrl-C), so a later apply never runs a second migration
# next to a still-running one. On failure the migration's log location is
# printed. No secrets are read or printed.
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: deploy/run-migration.sh   (called by Terraform during the app apply)

Runs LiteLLM's schema migration as a one-off ECS task and exits non-zero
unless it succeeds, so the service rollout waits for a migrated database.

Environment:
  CLUSTER, TASK_DEFINITION, SUBNETS, SECURITY_GROUPS, AWS_REGION   (required)
  MIGRATION_TIMEOUT_SECONDS  wait limit in seconds (default 1200); on timeout
                             the task is stopped and the apply fails. Export
                             it before deploy/deploy.sh to allow longer.
  MIGRATION_POLL_SECONDS     poll interval in seconds (default 15)
EOF
  exit 0
fi

: "${CLUSTER:?}" "${TASK_DEFINITION:?}" "${SUBNETS:?}" "${SECURITY_GROUPS:?}" "${AWS_REGION:?}"
TIMEOUT="${MIGRATION_TIMEOUT_SECONDS:-1200}"
POLL="${MIGRATION_POLL_SECONDS:-15}"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ && "$POLL" =~ ^[1-9][0-9]*$ ]] ||
  { echo "MIGRATION_TIMEOUT_SECONDS and MIGRATION_POLL_SECONDS must be positive integers" >&2; exit 2; }

TASK_ARN=""
TASK_STOPPED=false
STOP_REASON="Migration script exited before the task stopped"

# Where the migration container logs: read from the task definition, so it
# follows whatever log configuration the app gives it.
print_log_location() {
  local name group prefix
  read -r name group prefix < <(aws ecs describe-task-definition --region "$AWS_REGION" \
    --task-definition "$TASK_DEFINITION" \
    --query 'taskDefinition.containerDefinitions[0].[name, logConfiguration.options."awslogs-group", logConfiguration.options."awslogs-stream-prefix"]' \
    --output text 2>/dev/null) || true
  if [ -n "${group:-}" ] && [ "$group" != "None" ]; then
    echo "Migration logs: log group ${group}, stream prefix ${prefix} (this task: ${prefix}/${name}/${TASK_ARN##*/})" >&2
  else
    echo "Migration logs: see the log configuration of task definition ${TASK_DEFINITION}" >&2
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [ -n "$TASK_ARN" ] && [ "$TASK_STOPPED" != true ]; then
    echo "Stopping migration task ${TASK_ARN}" >&2
    aws ecs stop-task --region "$AWS_REGION" --cluster "$CLUSTER" --task "$TASK_ARN" \
      --reason "$STOP_REASON" >/dev/null ||
      echo "Could not stop ${TASK_ARN}; stop it manually before the next apply." >&2
  fi
  if [ "$rc" -ne 0 ] && [ -n "$TASK_ARN" ]; then
    print_log_location
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Starting migration task ${TASK_DEFINITION} on ${CLUSTER}"
TASK_ARN=$(aws ecs run-task \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEFINITION" \
  --launch-type FARGATE \
  --count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${SECURITY_GROUPS}],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
  TASK_ARN=""
  echo "Could not start the migration task" >&2
  exit 1
fi

echo "Waiting up to ${TIMEOUT}s for ${TASK_ARN}"
deadline=$((SECONDS + TIMEOUT))
while :; do
  STATUS=$(aws ecs describe-tasks --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
    --query 'tasks[0].lastStatus' --output text)
  if [ "$STATUS" = "STOPPED" ]; then
    TASK_STOPPED=true
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "Migration task ${TASK_ARN} still ${STATUS} after ${TIMEOUT}s." >&2
    STOP_REASON="Migration timed out after ${TIMEOUT}s"
    echo "The service was not rolled. Export MIGRATION_TIMEOUT_SECONDS (seconds) before deploying if the migration needs longer." >&2
    exit 1
  fi
  sleep "$POLL"
done

EXIT_CODE=$(aws ecs describe-tasks --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)
REASON=$(aws ecs describe-tasks --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].stoppedReason' --output text)

if [ "$EXIT_CODE" != "0" ]; then
  echo "Migration failed (exit code ${EXIT_CODE}, ${REASON}). The service was not rolled." >&2
  exit 1
fi
echo "Migration succeeded"
