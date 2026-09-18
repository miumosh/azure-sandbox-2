#!/usr/bin/env bash
# ============================================================================
# Key Vault 閉域化の影響を実測するスクリプト
#
# 使い方:
#   ./scripts/verify.sh            # 現在 apply されているモードで検証
#   ./scripts/verify.sh --with-provisioning
#                                  # 新規 Project 作成 (プロビジョニング経路) も検証
#
# 出力:
#   results/<mode>-<timestamp>.md  (results/ は .gitignore 済み)
#   標準出力にも同じサマリを出す
#
# 検証する経路:
#   T1 接続 GET            : ARM のメタデータ参照のみ。Key Vault を経由しない
#   T2 接続 listsecrets    : RP -> Key Vault の「読み取り」。SAS の解決そのもの
#   T3 接続の新規作成 (SAS): RP -> Key Vault の「書き込み」。キャッシュが効かない経路
#   T4 対照群 AAD 接続     : シークレットを持たない接続。Key Vault 非経由
#   T5 運用端末 -> KV      : 人間 / CI から Key Vault データ面に届くか
#   T6 Hub の状態          : Hub 本体が壊れていないか (provisioningState)
#   T7 新規 Project 作成   : Key Vault を触るプロビジョニング経路 (--with-provisioning 時のみ)
#   T8 既定データストア     : Hub が自動作成する workspaceblobstore の資格情報解決。
#                            AI Foundry 自身が SAS / AccountKey を Key Vault に置いている経路
# ============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

WITH_PROVISIONING=0
[[ "${1:-}" == "--with-provisioning" ]] && WITH_PROVISIONING=1

API_VERSION="2024-10-01"
ARM="https://management.azure.com"

echo "terraform output を読み込み中..." >&2
TF_JSON="$(terraform output -json)" || { echo "terraform output に失敗しました" >&2; exit 1; }

get() { jq -r "$1" <<<"$TF_JSON"; }

MODE="$(get '.key_vault_network_mode.value')"
SUB="$(get '.subscription_id.value')"
RG="$(get '.resource_group_name.value')"
KV_NAME="$(get '.key_vault.value.name')"
KV_PUBLIC="$(get '.key_vault.value.public_network_access_enabled')"
KV_BYPASS="$(az keyvault show -n "$(get '.key_vault.value.name')" --query "properties.networkAcls.bypass" -o tsv 2>/dev/null || echo "?")"
HUB_ID="$(get '.ai_foundry.value.hub_id')"
HUB_PUBLIC="$(get '.ai_foundry.value.hub_public_network')"
PROJ_ID="$(get '.ai_foundry.value.project_id')"
SA_NAME="$(get '.storage_data.value.name')"
SA_ID="$(get '.storage_data.value.id')"
BLOB_EP="$(get '.storage_data.value.primary_blob_endpoint')"
CONTAINER="$(get '.storage_data.value.container')"
CONN_HUB_SAS="$(get '.connections.value.hub_blob_sas.id')"
CONN_PROJ_SAS="$(get '.connections.value.project_blob_sas.id')"
CONN_PROJ_AAD="$(get '.connections.value.project_blob_aad.id')"

TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p results
OUT="results/${MODE}-${TS}.md"

RESULT_ROWS=()

# ---- ヘルパ ----------------------------------------------------------------
# run_test <ID> <名前> <期待> <コマンド...>
run_test() {
  local id="$1" name="$2" expect="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  local status detail
  if [[ $rc -eq 0 ]]; then
    status="OK"
  else
    status="NG"
  fi
  # レスポンスから機微情報 (SAS / キー) を落とす
  detail="$(sed -E 's/(sv=|sig=|se=|sasToken"?\s*:\s*")[^"&[:space:]]*/\1***REDACTED***/g' <<<"$out" \
            | tr '\n' ' ' | sed -E 's/  +/ /g' | cut -c1-260)"
  RESULT_ROWS+=("${id}|${name}|${expect}|${status}|${detail}")
  printf '  [%s] %-44s %s\n' "$status" "$name" "$id" >&2
  [[ -n "$detail" ]] && printf '        %s\n' "$detail" >&2
}

arm_get() { az rest --method get --url "${ARM}${1}?api-version=${API_VERSION}" -o json >/dev/null; }

arm_listsecrets_masked() {
  # 成功時は authType と「SAS が返ったか」だけを出す (SAS 本体は出力しない)
  local body
  body="$(az rest --method post --url "${ARM}${1}/listsecrets?api-version=${API_VERSION}" -o json)" || return 1
  jq -r '"authType=\(.properties.authType) credentials_returned=\(
      if (.properties.credentials // {} | to_entries | map(select(.value != null and .value != "")) | length) > 0
      then "yes" else "no" end)"' <<<"$body"
}

TEMP_CONN_NAME="conn-verify-tmp-${TS}"
create_temp_sas_connection() {
  # 新しい SAS で接続を新規作成する = RP が Key Vault へ「書き込み」を行う経路。
  # 既存シークレットのキャッシュでは説明できないため、閉域化の影響が最も明確に出る。
  local sas
  sas="$(az storage container generate-sas \
          --account-name "$SA_NAME" --name "$CONTAINER" \
          --permissions rl --expiry "$(date -u -d '+1 day' '+%Y-%m-%dT%H:%MZ')" \
          --auth-mode key --account-key "$(az storage account keys list -n "$SA_NAME" -g "$RG" --query '[0].value' -o tsv)" \
          -o tsv)" || return 1

  local body
  body="$(jq -n --arg t "${BLOB_EP}${CONTAINER}" --arg sas "$sas" --arg rid "$SA_ID" \
           --arg acct "$SA_NAME" --arg cont "$CONTAINER" '{
    properties: {
      category: "AzureBlob", target: $t, authType: "SAS",
      credentials: { sas: $sas },
      metadata: { ApiType: "Azure", ResourceId: $rid, accountName: $acct, containerName: $cont }
    }}')"

  az rest --method put \
    --url "${ARM}${PROJ_ID}/connections/${TEMP_CONN_NAME}?api-version=${API_VERSION}" \
    --headers "Content-Type=application/json" \
    --body "$body" -o json >/dev/null
}

delete_temp_sas_connection() {
  az rest --method delete \
    --url "${ARM}${PROJ_ID}/connections/${TEMP_CONN_NAME}?api-version=${API_VERSION}" -o none 2>/dev/null
}

TEMP_PROJ_NAME="aifp-verify-tmp-${TS: -6}"
create_temp_project() {
  # Hub 配下に Project を新規作成する = ワークスペースのプロビジョニング経路。
  local body
  body="$(jq -n --arg loc "$(az group show -n "$RG" --query location -o tsv)" --arg hub "$HUB_ID" '{
    location: $loc, kind: "Project", identity: { type: "SystemAssigned" },
    properties: { hubResourceId: $hub, friendlyName: "verify temp project" }}')"
  az rest --method put \
    --url "${ARM}/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.MachineLearningServices/workspaces/${TEMP_PROJ_NAME}?api-version=${API_VERSION}" \
    --headers "Content-Type=application/json" --body "$body" -o json >/dev/null
}

delete_temp_project() {
  az rest --method delete \
    --url "${ARM}/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.MachineLearningServices/workspaces/${TEMP_PROJ_NAME}?api-version=${API_VERSION}" -o none 2>/dev/null
}

datastore_listsecrets() {
  # Hub が自動作成する既定データストア (workspaceblobstore) の資格情報。
  # これも Key Vault に SAS / AccountKey として保存されている。
  az rest --method post \
    --url "${ARM}${PROJ_ID}/datastores/workspaceblobstore/listSecrets?api-version=${API_VERSION}" \
    -o json | jq -r '"secretsType=\(.secretsType // "unknown")"'
}

hub_provisioning_state() {
  az rest --method get --url "${ARM}${HUB_ID}?api-version=${API_VERSION}" \
    --query "properties.provisioningState" -o tsv
}

# ---- 実行 ------------------------------------------------------------------
echo "" >&2
echo "=== Key Vault 閉域化 影響検証 (mode=${MODE}) ===" >&2
echo "  Key Vault           : ${KV_NAME} (public=${KV_PUBLIC} / bypass=${KV_BYPASS})" >&2
echo "  AI Foundry Hub      : public_network_access=${HUB_PUBLIC} (インバウンドのみ閉域化)" >&2
echo "" >&2

run_test T1 "接続 GET (メタデータのみ / KV 非経由)" "常に OK" \
  arm_get "$CONN_HUB_SAS"

run_test T2a "listsecrets: Hub の SAS 接続 (RP -> KV 読取)" "閉域化の影響を受けるか" \
  arm_listsecrets_masked "$CONN_HUB_SAS"

run_test T2b "listsecrets: Project の SAS 接続 (RP -> KV 読取)" "閉域化の影響を受けるか" \
  arm_listsecrets_masked "$CONN_PROJ_SAS"

run_test T3 "SAS 接続の新規作成 (RP -> KV 書込)" "閉域化の影響を受けるか" \
  create_temp_sas_connection
delete_temp_sas_connection

run_test T4 "listsecrets: AAD 接続 (対照群 / KV 非経由)" "常に OK" \
  arm_listsecrets_masked "$CONN_PROJ_AAD"

run_test T5 "運用端末 -> Key Vault データ面 (secret list)" "private では NG の想定" \
  az keyvault secret list --vault-name "$KV_NAME" --query "[].name" -o tsv

run_test T6 "Hub の provisioningState" "常に Succeeded" \
  hub_provisioning_state

run_test T8 "既定データストア workspaceblobstore の資格情報解決" "閉域化の影響を受けるか" \
  datastore_listsecrets

if [[ $WITH_PROVISIONING -eq 1 ]]; then
  run_test T7 "Project の新規作成 (プロビジョニング経路)" "閉域化の影響を受けるか" \
    create_temp_project
  delete_temp_project
fi

# ---- 出力 ------------------------------------------------------------------
{
  echo "# Key Vault 閉域化 影響検証結果 (mode = ${MODE})"
  echo ""
  echo "- 実行日時: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- Key Vault: \`${KV_NAME}\` / networkAcls.bypass = \`${KV_BYPASS}\` / publicNetworkAccess 有効 = \`${KV_PUBLIC}\`"
  echo "- AI Foundry Hub: publicNetworkAccess = \`${HUB_PUBLIC}\` (インバウンドのみ閉域化 / managed VNet なし)"
  echo "- 接続先 Storage: \`${SA_NAME}\` / コンテナ \`${CONTAINER}\` (public のまま = 交絡要因なし)"
  echo ""
  echo "| ID | 検証項目 | 観点 | 結果 | 詳細 |"
  echo "|----|----------|------|------|------|"
  for row in "${RESULT_ROWS[@]}"; do
    IFS='|' read -r id name expect status detail <<<"$row"
    printf '| %s | %s | %s | %s | %s |\n' "$id" "$name" "$expect" "$status" "${detail//|/\\|}"
  done
} | tee "$OUT"

echo "" >&2
echo "結果を ${OUT} に保存しました。" >&2
