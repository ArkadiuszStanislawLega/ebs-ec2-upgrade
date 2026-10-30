#!/usr/bin/env bash

set -euo pipefail

ACTION="${1:-}"
NAME_PREFIX="${2:-oracle-ebs-scaler}"

if [[ -z "${ACTION}" ]]; then
  echo "Usage: $0 {status|disable|enable|logs|force-scaledown} [name-prefix]" >&2
  exit 1
fi

RULE_NAME="${NAME_PREFIX}-scaledown-check"
LOG_GROUP="/aws/lambda/${NAME_PREFIX}"

get_managed_alarms() {
  aws cloudwatch describe-alarms \
    --alarm-name-prefix "${NAME_PREFIX}-saturation-" \
    --query 'MetricAlarms[*].AlarmName' \
    --output text
}

cmd_status() {
  echo "=== Managed CloudWatch Alarms (${NAME_PREFIX}) ==="
  aws cloudwatch describe-alarms \
    --alarm-name-prefix "${NAME_PREFIX}-saturation-" \
    --query 'MetricAlarms[*].{AlarmName:AlarmName,State:StateValue,ActionsEnabled:ActionsEnabled,ThresholdMBps:Threshold}' \
    --output table

  echo "=== Shared EventBridge Scale-Down Rule ==="
  aws events describe-rule \
    --name "${RULE_NAME}" \
    --query '{RuleName:Name,State:State,Schedule:ScheduleExpression}' \
    --output table
}

cmd_disable() {
  local alarms
  alarms=$(get_managed_alarms)
  if [[ -n "${alarms}" ]]; then
    # shellcheck disable=SC2086
    aws cloudwatch disable-alarm-actions --alarm-names ${alarms}
  fi
  aws events disable-rule --name "${RULE_NAME}"
  echo "[+] Kill-Switch active: All scale-up alarms and scale-down schedules disabled."
  cmd_status
}

cmd_enable() {
  local alarms
  alarms=$(get_managed_alarms)
  if [[ -n "${alarms}" ]]; then
    # shellcheck disable=SC2086
    aws cloudwatch enable-alarm-actions --alarm-names ${alarms}
  fi
  aws events enable-rule --name "${RULE_NAME}"
  echo "[+] Automation armed: All triggers enabled."
  cmd_status
}

cmd_logs() {
  aws logs tail "${LOG_GROUP}" --since 24h --follow
}

cmd_force_scaledown() {
  local out_file
  out_file=$(mktemp)
  trap 'rm -f "${out_file}"' RETURN

  echo "[*] Invoking batch scale_down evaluation across all managed volumes..."
  aws lambda invoke \
    --function-name "${NAME_PREFIX}" \
    --cli-binary-format raw-in-base64-out \
    --payload '{"action": "scale_down"}' \
    "${out_file}" >/dev/null

  cat "${out_file}"
  echo ""
}

case "${ACTION}" in
status) cmd_status ;;
disable) cmd_disable ;;
enable) cmd_enable ;;
logs) cmd_logs ;;
force-scaledown) cmd_force_scaledown ;;
*)
  echo "ERROR: Unsupported action '${ACTION}'." >&2
  exit 1
  ;;
esac
