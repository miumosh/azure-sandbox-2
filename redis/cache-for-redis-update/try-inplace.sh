#!/usr/bin/env bash
# ============================================================================
# 検証 (3): replace を伴わずに単一ゾーン -> 複数ゾーンへ変えられる経路を探す。
#
#   ./try-inplace.sh show        現在の zones / zonalAllocationPolicy を確認
#   ./try-inplace.sh cli         az CLI で zones を変えられるか試す
#   ./try-inplace.sh api-zones   REST API で zones を直接指定して PATCH してみる
#   ./try-inplace.sh api-auto    REST API で zonalAllocationPolicy=Automatic に更新
#                                ★ 不可逆。実行前に確認を求める
#
# 各コマンドの生の応答は out/ に保存する。
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

out="out"
mkdir -p "$out"

json=$(terraform output -json)
jqv() { echo "$json" | jq -r "$1"; }

SUB=$(grep -E '^\s*subscription_id' terraform.tfvars | sed -E 's/.*"(.*)".*/\1/')
RG=$(jqv '.resource_group_name.value')
NAME=$(jqv '.redis_name.value')
ID=$(jqv '.redis_id.value')
APIV=$(jqv '.arm_api_version.value')

# ARM の Redis リソースの現在値を表示する。
# zones はトップレベル、zonalAllocationPolicy は properties 配下にある。
show_state() {
  echo "--- 現在の ARM 上の状態 ---"
  az rest --method get \
    --url "https://management.azure.com${ID}?api-version=${APIV}" \
    --query '{zones:zones, zonalAllocationPolicy:properties.zonalAllocationPolicy, provisioningState:properties.provisioningState, instanceZones:properties.instances[].zone}' \
    -o jsonc
}

echo "=========================================================="
echo " Subscription : ${SUB}"
echo " Redis        : ${RG} / ${NAME}"
echo " API version  : ${APIV}"
echo "=========================================================="
echo

case "${1:-show}" in

  show)
    show_state
    echo
    echo "--- Terraform が認識している zones ---"
    jqv '.redis_zones.value'
    ;;

  # --------------------------------------------------------------------
  # 経路 A: az CLI
  # `az redis update` には --zones も --zonal-allocation-policy も無い。
  # (`az redis create` にはどちらもある = 作成時専用のパラメータ)
  # 汎用の --set で無理やり押し込めるかを試す。
  # --------------------------------------------------------------------
  cli)
    echo "--- az redis update のパラメータ一覧 (zones があるか確認) ---"
    az redis update --help 2>&1 | sed -n '/^Arguments/,/^Generic Update Arguments/p'
    echo
    echo "--- 汎用 --set で zones を押し込んでみる (失敗するはず) ---"
    set +e
    az redis update --subscription "$SUB" -g "$RG" -n "$NAME" \
      --set 'zones=["1","2"]' -o jsonc 2>&1 | tee "${out}/cli-set-zones.txt"
    echo "exit=${PIPESTATUS[0]}"
    set -e
    ;;

  # --------------------------------------------------------------------
  # 経路 B: REST API で zones を直接指定
  # Update (PATCH) のリクエストボディ定義 RedisUpdateParameters に zones は
  # 含まれていない (含まれるのは Create の RedisResource のみ)。
  # 送っても弾かれるか黙って無視されるかを実機で確かめる。
  # --------------------------------------------------------------------
  api-zones)
    echo "--- 変更前 ---"; show_state; echo
    body='{"zones":["1","2"]}'
    echo "--- PATCH ${body} ---"
    set +e
    az rest --method patch \
      --url "https://management.azure.com${ID}?api-version=${APIV}" \
      --headers "Content-Type=application/json" \
      --body "$body" -o jsonc 2>&1 | tee "${out}/api-patch-zones.txt"
    echo "exit=${PIPESTATUS[0]}"
    set -e
    echo
    echo "--- 変更後 (zones が実際に変わったか) ---"; show_state
    ;;

  # --------------------------------------------------------------------
  # 経路 C: REST API で zonalAllocationPolicy = Automatic
  # ドキュメント上、既存キャッシュを in-place でゾーン冗長化できる唯一の方法。
  # ただし「Azure が自動で選んだゾーン」になり、ゾーンの明示指定はできない。
  # かつ一度有効にすると戻せない。
  # --------------------------------------------------------------------
  api-auto)
    echo "--- 変更前 ---"; show_state; echo
    cat <<'WARN'
★ 警告
  zonalAllocationPolicy = Automatic への変更は **不可逆** です。
  - 一度有効にすると無効化 / 他の値への変更はできません
  - 割り当てられるゾーンは Azure が選ぶため、明示指定はできません
  - VNet インジェクション構成 / geo レプリケーション構成のキャッシュでは非対応
WARN
    read -r -p "続行しますか? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "中止しました。"; exit 0; }

    body='{"properties":{"zonalAllocationPolicy":"Automatic"}}'
    echo "--- PATCH ${body} ---"
    set +e
    az rest --method patch \
      --url "https://management.azure.com${ID}?api-version=${APIV}" \
      --headers "Content-Type=application/json" \
      --body "$body" -o jsonc 2>&1 | tee "${out}/api-patch-zonal-auto.txt"
    echo "exit=${PIPESTATUS[0]}"
    set -e

    echo
    echo "--- 反映待ち (provisioningState が Succeeded になるまで) ---"
    for _ in $(seq 1 60); do
      st=$(az rest --method get \
        --url "https://management.azure.com${ID}?api-version=${APIV}" \
        --query 'properties.provisioningState' -o tsv)
      echo "  provisioningState=${st}"
      [ "$st" = "Succeeded" ] && break
      sleep 30
    done

    echo
    echo "--- 変更後 ---"; show_state
    echo
    echo "--- この状態で terraform plan を打つと何が起きるか ---"
    set +e
    terraform plan -no-color -detailed-exitcode | tee "${out}/plan-after-api-auto.txt" >/dev/null
    rc="${PIPESTATUS[0]}"
    set -e
    grep -E 'forces replacement|must be replaced|^Plan: |No changes' "${out}/plan-after-api-auto.txt" || true
    echo "(plan 全文: ${out}/plan-after-api-auto.txt / exitcode=${rc})"
    ;;

  *)
    echo "usage: $0 show|cli|api-zones|api-auto" >&2
    exit 1
    ;;
esac
