#!/usr/bin/env bash
# ============================================================================
# Azure 側の maintenanceConfiguration を ARM API で直接読む
# (Terraform の state ではなく実機の値を見るため。ポータル変更後のドリフト確認にも使う)
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

id=$(terraform output -raw managed_redis_id)
api=$(terraform output -raw arm_api_version)

az rest --method get \
  --url "https://management.azure.com${id}?api-version=${api}" \
  --query "properties.maintenanceConfiguration" -o json
