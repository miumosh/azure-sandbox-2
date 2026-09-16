#!/usr/bin/env bash
# ============================================================================
# サブスクリプションで Azure Cache for Redis を新規作成できるか判定する。
# 詳細な調査結果は creation-eligibility.md を参照。
#
#   ./check-eligibility.sh            全サブスクリプションの既存インスタンスを一覧 (安全)
#   ./check-eligibility.sh <SUB_ID> <RG>
#                                     実作成プローブで確定判定する
#                                     ★ ブロックされていない場合は Basic C0 が実際に
#                                        作成されるため、成功時は即削除すること
# ============================================================================
set -euo pipefail

# ---- 引数なし: 既存インスタンスの棚卸し (完全に安全) ----------------------
if [ $# -eq 0 ]; then
  echo "=== アクセス可能なサブスクリプションの既存 Azure Cache for Redis ==="
  echo "  (1 件以上 = 既存顧客扱いで作成できる可能性が高い / 0 件 = ブロックの可能性が高い)"
  echo
  az account list --all --query "[?state=='Enabled'].[name,id]" -o tsv \
  | while IFS=$'\t' read -r name id; do
      count=$(az redis list --subscription "$id" --query 'length(@)' -o tsv 2>/dev/null || echo "取得不可")
      printf '  %-30s %s : %s 件\n' "$name" "$id" "$count"
    done
  echo
  echo "確定させるには: $0 <SUB_ID> <既存の RG 名>"
  exit 0
fi

# ---- 引数あり: 実作成プローブ ---------------------------------------------
SUB="$1"
RG="${2:-}"
if [ -z "$RG" ]; then
  echo "usage: $0 <SUB_ID> <RG>" >&2
  exit 1
fi

NAME="probe-redis-$$-${RANDOM}"
URL="https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Cache/redis/${NAME}?api-version=2024-11-01"

cat <<WARN
=========================================================================
 実作成プローブ
   Subscription : ${SUB}
   ResourceGroup: ${RG}
   Cache name   : ${NAME}  (Basic C0 = 最安 SKU)

 ★ このサブスクリプションがブロックされていない場合、Basic C0 の
    キャッシュが【実際に作成されます】。成功したら即削除してください。
=========================================================================
WARN
read -r -p "続行しますか? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "中止しました。"; exit 0; }

set +e
resp=$(az rest --method put --url "$URL" \
  --headers "Content-Type=application/json" \
  --body '{"location":"japaneast","properties":{"sku":{"name":"Basic","family":"C","capacity":0}}}' 2>&1)
rc=$?
set -e

echo "$resp"
echo

if echo "$resp" | grep -q "is retiring"; then
  echo "判定: ★ 作成不可 (退役ゲートでブロック済み)。リソースは作られていません。"
elif [ "$rc" -eq 0 ]; then
  echo "判定: ★ 作成可能。ただし実リソースの作成が始まっています。"
  echo
  echo "--- 即削除します ---"
  az redis delete --subscription "$SUB" -g "$RG" -n "$NAME" --yes
  echo "削除を要求しました。az redis list -g ${RG} で消えたことを確認してください。"
else
  echo "判定: 別の理由で失敗 (exit=${rc})。上のエラー内容を確認してください。"
fi
