#!/usr/bin/env bash
# ============================================================================
# 検証 (3): zones の変更が plan 上 replace / in-place のどちらになるか確認する。
#
#   ./plan-zones.sh                                   # 既定: 両方 ["1","2","3"]
#   ./plan-zones.sh '["1","2","3"]' 'null'            # system / user を個別指定
#   ./plan-zones.sh '["1","2","3"]' '["1","2","3"]' false
#                                                     # temporary_name_for_rotation なし
#
# 変更後の値は -var で渡すだけなので terraform.tfvars は書き換えない。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

system_zones="${1:-[\"1\",\"2\",\"3\"]}"
user_zones="${2:-[\"1\",\"2\",\"3\"]}"
use_tmp="${3:-true}"
out="out"
mkdir -p "$out"
log="${out}/plan-zones.txt"

echo "=========================================================="
echo " system_zones : ${system_zones}"
echo " user_zones   : ${user_zones}"
echo " temporary_name_for_rotation : ${use_tmp}"
echo "=========================================================="

set +e
terraform plan -no-color -detailed-exitcode -out "${out}/zones.tfplan" \
  -var "system_zones=${system_zones}" \
  -var "user_zones=${user_zones}" \
  -var "use_temporary_name_for_rotation=${use_tmp}" \
  | tee "$log"
rc="${PIPESTATUS[0]}"
set -e

echo
echo "=========================================================="
case "$rc" in
  0) echo " 結果: 差分なし" ;;
  2) echo " 結果: 差分あり" ;;
  *) echo " 結果: plan が失敗した (exit=${rc})"; exit "$rc" ;;
esac

# 機械可読な plan からリソースごとの action を出す (表示の読み違いを避ける)
terraform show -json "${out}/zones.tfplan" > "${out}/zones.tfplan.json"
echo " --- リソースごとの action (create+delete なら replace) ---"
jq -r '.resource_changes[] | select(.change.actions != ["no-op"])
       | "\(.address)\t\(.change.actions | join("+"))"' "${out}/zones.tfplan.json"
echo
grep -E '^Plan: ' "$log" || true
echo "=========================================================="
echo " plan 全文: ${log}"
echo " ※ plan が update でも、azurerm は apply 時にノードプールを作り直す (README 参照)"
