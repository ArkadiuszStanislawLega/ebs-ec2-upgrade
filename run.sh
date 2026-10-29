#!/usr/bin/env bash
set -euo pipefail

# 1. Lokalny test logiki Pythona (pytest + Stubber):
pytest -v tests/test_scaler_unit.py

# 2. Postawienie swiezego srodowiska PoC v2:
cd terraform
terraform init
terraform apply -auto-approve

INSTANCE_ID=$(terraform output -raw instance_id)
echo "Czekam 45 sekund na Cloud-Init i otwieram sesje SSM..."
sleep 45
aws ssm start-session --region eu-central-1 --target "${INSTANCE_ID}"
