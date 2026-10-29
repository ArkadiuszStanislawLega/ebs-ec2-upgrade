#!/usr/bin/env bash

set -euo pipefail

TFVARS_FILE="${1:-terraform/terraform.tfvars}"

if [[ ! -f "${TFVARS_FILE}" ]]; then
  echo "ERROR: File '${TFVARS_FILE}' does not exist!" >&2
  exit 1
fi

VOL_ID=$(awk -F'"' '/^volume_id/ {print $2}' "${TFVARS_FILE}")

if [[ -z "${VOL_ID}" ]]; then
  echo "ERROR: 'volume_id' not found in ${TFVARS_FILE}" >&2
  exit 1
fi

if [[ "${VOL_ID}" == "vol-0123456789abcdef0" ]]; then
  echo "ERROR: You are still using the placeholder volume_id (${VOL_ID}) in ${TFVARS_FILE}!" >&2
  exit 1
fi

CURRENT_REGION=$(aws configure get region || echo "not-set")
echo "[*] Extracted volume_id: '${VOL_ID}'"
echo "[*] Default AWS CLI region: '${CURRENT_REGION}'"
echo "[*] Searching for volume across commonly used EU/US regions..."

for reg in eu-central-1 eu-west-1 us-east-1; do
  RES=$(aws ec2 describe-volumes \
    --region "${reg}" \
    --filters "Name=volume-id,Values=${VOL_ID}" \
    --query 'Volumes[0].{VolumeId:VolumeId,State:State,Type:VolumeType,AZ:AvailabilityZone}' \
    --output json 2>/dev/null || true)

  if [[ -n "${RES}" && "${RES}" != "null" ]]; then
    echo "[+] FOUND volume in region '${reg}':"
    echo "${RES}"
    exit 0
  fi
done

echo "[!] Volume '${VOL_ID}' was NOT found in eu-central-1, eu-west-1, or us-east-1 under the current AWS profile." >&2
exit 1
