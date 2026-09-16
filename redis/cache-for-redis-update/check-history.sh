#!/usr/bin/env bash
# ============================================================================
# 「組織で過去に Azure Cache for Redis を作成したことがあるか」を調べる。
# すべて読み取り専用。詳細は creation-eligibility.md の追補を参照。
#
#   ./check-history.sh          アクセス可能な全サブスクリプションを調査
#   ./check-history.sh <SUB_ID> 特定のサブスクリプションのみ
#
# 遡及範囲の上限:
#   現存リソース     : 現在のみ
#   アクティビティログ: 90 日
#   課金実績         : 約 1 年
# これより前に作成して削除済みのケースは追えない。
# ============================================================================
set -euo pipefail

echo "=============================================================="
echo " Azure Cache for Redis の作成履歴調査"
echo "=============================================================="
echo

# ---- 組織の範囲 -----------------------------------------------------------
echo "### 1. アクセス可能なサブスクリプションとテナント"
az account list --all --query "[?state=='Enabled'].{name:name, id:id, tenant:tenantId}" -o table
echo
echo "  ※ RBAC が付いているものしか見えない。組織全体を網羅するには"
echo "     管理グループ Reader か課金アカウントへのアクセスが必要。"
if az account management-group list -o none 2>/dev/null; then
  echo "  管理グループ: 参照可能"
  az account management-group list --query '[].{name:displayName, id:name}' -o table
else
  echo "  管理グループ: 参照不可 (権限なし)"
fi
echo

# ---- 現存リソース (Resource Graph で横断) ---------------------------------
echo "### 2. 現存する Azure Cache for Redis (Resource Graph / 全サブスク横断)"
if az graph query -q "resources | where type =~ 'microsoft.cache/redis' | project name, subscriptionId, resourceGroup, location" -o table 2>/dev/null; then
  :
else
  echo "  resource-graph 拡張が必要: az extension add -n resource-graph"
fi
echo

# ---- 対象サブスクリプションの決定 -----------------------------------------
if [ $# -ge 1 ]; then
  subs="$1"
else
  subs=$(az account list --all --query "[?state=='Enabled'].id" -o tsv)
fi

# ---- 履歴系 ---------------------------------------------------------------
echo "### 3. 作成履歴 (アクティビティログ 90 日 / 課金実績 約1年)"
echo
printf '  %-38s %-10s %-12s %s\n' "SUBSCRIPTION" "現存" "作成成功(90d)" "課金実績(1y)"
printf '  %-38s %-10s %-12s %s\n' "--------------------------------------" "------" "-----------" "-----------"

start=$(date -u -d '1 year ago' +%Y-%m-%d 2>/dev/null || date -u -v-1y +%Y-%m-%d)
end=$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d)

for s in $subs; do
  name=$(az account list --all --query "[?id=='$s'].name" -o tsv 2>/dev/null | head -1)

  cur=$(az redis list --subscription "$s" --query 'length(@)' -o tsv 2>/dev/null || echo "?")

  created=$(az monitor activity-log list --subscription "$s" --offset 89d \
    --namespace Microsoft.Cache \
    --query "length([?status.value=='Succeeded' && operationName.value=='Microsoft.Cache/redis/write'])" \
    -o tsv 2>/dev/null || echo "?")

  billed=$(timeout 115 az consumption usage list --subscription "$s" \
    --start-date "$start" --end-date "$end" --top 1000 \
    --query "length([?consumedService=='Microsoft.Cache' || consumedService=='microsoft.cache'])" \
    -o tsv 2>/dev/null || echo "?")

  printf '  %-38s %-10s %-12s %s\n' "${name:-$s}" "$cur" "$created" "$billed"
done

cat <<'NOTE'

  凡例 / 解釈
    現存         > 0 … 今も使っている。作成可能
    作成成功(90d)> 0 … 直近 90 日に作成実績あり。作成可能な可能性が高い
    課金実績(1y) > 0 … 削除済みでも過去 1 年に使っていた証跡あり
    ?                … 取得失敗 (権限不足 / タイムアウト / API 制限)

  すべて 0 でも「1 年より前に作成して削除済み」の可能性は否定できない。
  確定させるには実作成プローブを使う:
      ./check-eligibility.sh <SUB_ID> <RG>
NOTE
