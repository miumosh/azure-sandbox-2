#!/usr/bin/env bash
# ============================================================================
# 検証 (2): 単一ゾーン -> 複数ゾーンへの変更が replace になることを確認する。
#
#   ./plan-zones.sh '["1","2"]'      # 既定。2 ゾーンへの変更を plan
#   ./plan-zones.sh '["2"]'          # 別の単一ゾーンへの変更を plan
#   ./plan-zones.sh '["1","2","3"]'  # 3 ゾーン (ノード数が足りずエラーになるはず)
#
# plan の終了コードで判定する (-detailed-exitcode: 0=差分なし / 2=差分あり)。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

zones="${1:-[\"1\",\"2\"]}"
out="out"
mkdir -p "$out"

echo "=========================================================="
echo " 変更後の zones : ${zones}"
echo "=========================================================="

# plan を保存しつつ標準出力にも流す
set +e
terraform plan -var "redis_zones=${zones}" -detailed-exitcode -no-color \
  | tee "${out}/plan-zones.txt"
rc="${PIPESTATUS[0]}"
set -e

echo
echo "=========================================================="
case "$rc" in
  0) echo " 結果: 差分なし (現在の zones と同じ)" ;;
  2) echo " 結果: 差分あり" ;;
  *) echo " 結果: plan が失敗した (exit=${rc})"; exit "$rc" ;;
esac

# replace かどうかを判定する。
# Terraform は破棄を伴う変更を "must be replaced" / "forces replacement" と表示する。
if grep -qE 'must be replaced|forces replacement' "${out}/plan-zones.txt"; then
  echo " 判定: ★ replace (破棄 -> 再作成) が計画された"
  echo
  echo " --- forces replacement の該当行 ---"
  grep -nE 'forces replacement|# azurerm_redis_cache.* must be replaced' "${out}/plan-zones.txt" || true
  echo
  echo " --- サマリ ---"
  grep -E '^Plan: ' "${out}/plan-zones.txt" || true
elif [ "$rc" = "2" ]; then
  echo " 判定: in-place update (replace ではない)"
  grep -E '^Plan: ' "${out}/plan-zones.txt" || true
fi
echo "=========================================================="
echo " plan 全文: ${out}/plan-zones.txt"
