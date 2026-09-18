#!/usr/bin/env bash
# ============================================================================
# Key Vault の公開方式 × trusted services bypass の全組み合わせを
# apply -> 設定伝播待ち -> verify.sh の順に回すドライバ。
#
#   ./scripts/run_matrix.sh [伝播待ち秒数(既定 300)]
#
# 注意: Key Vault の networkAcls 変更はデータ面へ反映されるまで数分かかる。
#       短い待ち時間で測ると「read は通るのに write は落ちる」ような
#       中途半端な結果になるため、既定で 300 秒待ってから測定する。
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SETTLE="${1:-300}"

# mode:bypass の組み合わせ
COMBOS=(
  "public:true"
  "restricted:true"
  "restricted:false"
  "private:true"
  "private:false"
)

for combo in "${COMBOS[@]}"; do
  mode="${combo%%:*}"
  bypass="${combo##*:}"

  echo ""
  echo "############################################################"
  echo "# key_vault_network_mode=${mode} / bypass=AzureServices? ${bypass}"
  echo "############################################################"

  terraform apply -input=false -auto-approve \
    -var "key_vault_network_mode=${mode}" \
    -var "key_vault_trusted_azure_services_bypass=${bypass}" \
    2>&1 | grep -E "Apply complete|Error:" 

  echo "Key Vault のネットワーク設定が伝播するまで ${SETTLE} 秒待機..."
  sleep "$SETTLE"

  ./scripts/verify.sh --with-provisioning
done

echo ""
echo "全モードの検証が完了しました。results/ 配下を参照してください。"
