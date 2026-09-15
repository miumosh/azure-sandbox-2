#!/usr/bin/env bash
# ============================================================================
# 名前解決の検証スクリプト
#   RG3 の VM 上で dig を実行し、同名 Private DNS ゾーンの解決結果を確認する。
#   VM への SSH は不要 (az vm run-command 経由)。
#
# 使い方:  ./verify.sh
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

json=$(terraform output -json)
jqv() { echo "$json" | jq -r "$1"; }

SUB=$(grep -E '^\s*subscription_id' terraform.tfvars | sed -E 's/.*"(.*)".*/\1/')
RG3=$(jqv '.resource_group_names.value.rg3')
VM=$(jqv '.vm_name.value')
FQDN1=$(jqv '.storage_blob_fqdns.value.rg1')
FQDN2=$(jqv '.storage_blob_fqdns.value.rg2')
CONFLICT=$(jqv '.conflict_fqdn.value')
LINK=$(jqv '.vm_vnet_dns_link.value')

echo "=========================================================="
echo " VNet3 にリンク中のゾーン : ${LINK}"
echo " 期待値"
echo "   ${FQDN1} -> $(jqv '.private_endpoint_ips.value.rg1')  (RG1 の PE)"
echo "   ${FQDN2} -> $(jqv '.private_endpoint_ips.value.rg2')  (RG2 の PE)"
echo "   ${CONFLICT} -> rg1:$(jqv '.conflict_expected_ips.value.rg1') / rg2:$(jqv '.conflict_expected_ips.value.rg2')"
echo "=========================================================="

read -r -d '' SCRIPT <<SH || true
echo "### resolvectl status (DNS サーバは Azure 提供の 168.63.129.16 のはず)"
resolvectl status 2>/dev/null | grep -E "Current DNS|DNS Servers" | head -5
for f in ${FQDN1} ${FQDN2} ${CONFLICT}; do
  echo
  echo "### dig \$f"
  dig +noall +answer "\$f" || true
  echo "--- 解決結果(getent) ---"
  getent ahostsv4 "\$f" | head -2 || echo "  解決できません (NXDOMAIN / SERVFAIL)"
done
SH

az vm run-command invoke \
  --subscription "$SUB" -g "$RG3" -n "$VM" \
  --command-id RunShellScript \
  --scripts "$SCRIPT" \
  --query "value[0].message" -o tsv
