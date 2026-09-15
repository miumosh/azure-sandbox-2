#!/usr/bin/env bash
# ============================================================================
# VNet3 にリンクする Private DNS ゾーンを切り替える。
#
#   ./switch.sh rg1 | rg2 | both | none
#
# rg1 <-> rg2 の直接切り替えは、Terraform が「旧リンクの削除」と
# 「新リンクの作成」を並列実行するため、削除完了前に作成が走って
#   "A virtual network cannot be linked to multiple zones with overlapping namespaces"
# で失敗することがある。そのため一旦 none を経由する 2 段階で行う。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

target="${1:-rg1}"
case "$target" in
  rg1|rg2|both|none) ;;
  *) echo "usage: $0 rg1|rg2|both|none" >&2; exit 1 ;;
esac

if [ "$target" != "none" ]; then
  echo "--- step 1/2: 既存リンクを外す (none) ---"
  terraform apply -auto-approve -var vm_vnet_dns_link=none >/dev/null
fi

echo "--- step 2/2: ${target} を適用 ---"
terraform apply -auto-approve -var "vm_vnet_dns_link=${target}"
