#!/usr/bin/env bash
set -euo pipefail

cd terraform
VOL_ID=$(terraform output -raw data_volume_id)
FN_NAME="ebs-throughput-scaler-${VOL_ID}"

echo "[*] Testuje 3. modyfikacje pod rzad na tym samym wolumenie (${VOL_ID})..."
OUT_FILE=$(mktemp)
trap 'rm -f "${OUT_FILE}"' EXIT

aws lambda invoke \
  --region eu-central-1 \
  --function-name "${FN_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action": "scale_up"}' \
  "${OUT_FILE}" >/dev/null

echo "Wynik 3. modyfikacji:"
cat "${OUT_FILE}"
echo ""

echo "[*] Niszczymy srodowisko laboratoryjne PoC v2..."
terraform destroy -auto-approve
