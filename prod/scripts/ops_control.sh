#!/usr/bin/env bash
# scripts/ops_control.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_PATH="${SCRIPT_DIR}/../terraform/terraform.tfvars"

detect_tfvar() {
  local key="$1"
  local fallback="$2"
  if [[ ! -f "${TFVARS_PATH}" ]]; then
    echo "${fallback}"
    return
  fi
  local val
  val=$(awk -F'"' "/^[[:space:]]*${key}[[:space:]]*=/ {print \$2}" "${TFVARS_PATH}" | head -n 1)
  echo "${val:-${fallback}}"
}

ACTION="${1:-}"
NAME_PREFIX="${2:-$(detect_tfvar "name_prefix" "oracle-ebs-scaler")}"
TARGET_REGION="${3:-${AWS_REGION:-$(detect_tfvar "aws_region" "eu-central-1")}}"

if [[ -z "${ACTION}" ]]; then
  echo "Usage: $0 {status|disable|enable|logs|force-scaledown} [name-prefix] [aws-region]" >&2
  exit 1
fi

export AWS_REGION="${TARGET_REGION}"
export AWS_DEFAULT_REGION="${TARGET_REGION}"

RULE_NAME="${NAME_PREFIX}-scaledown-check"
LOG_GROUP="/aws/lambda/${NAME_PREFIX}"

get_managed_alarms() {
  aws cloudwatch describe-alarms \
    --alarm-name-prefix "${NAME_PREFIX}-saturation-" \
    --query 'MetricAlarms[*].AlarmName' \
    --output text
}

cmd_status() {
  echo "=== Target Context: Region=${TARGET_REGION} | Prefix=${NAME_PREFIX} ==="
  echo "=== Managed CloudWatch Alarms ==="
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
  echo "[+] Kill-Switch active in ${TARGET_REGION}: All triggers disabled."
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
  echo "[+] Automation armed in ${TARGET_REGION}: All triggers enabled."
  cmd_status
}

cmd_logs() {
  local found_group
  found_group=$(aws logs describe-log-groups \
    --log-group-name-prefix "${LOG_GROUP}" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
    --output text)

  if [[ -z "${found_group}" ]]; then
    echo "ERROR: Log group '${LOG_GROUP}' does not exist in region '${TARGET_REGION}'." >&2
    exit 1
  fi

  local stream_count
  stream_count=$(aws logs describe-log-streams \
    --log-group-name "${LOG_GROUP}" \
    --max-items 1 \
    --query 'length(logStreams)' \
    --output text)

  if [[ "${stream_count}" == "0" ]]; then
    echo "[!] Log group '${LOG_GROUP}' exists, but Lambda has not been invoked yet (0 log streams)."
    echo "[*] Run '$0 force-scaledown' first to generate initial execution logs."
    return 0
  fi

  aws logs tail "${LOG_GROUP}" --since 24h --follow
}

cmd_force_scaledown() {
  local out_file
  out_file=$(mktemp)
  trap 'rm -f "${out_file}"' RETURN

  echo "[*] Invoking batch scale_down on '${NAME_PREFIX}' in region '${TARGET_REGION}'..."
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
