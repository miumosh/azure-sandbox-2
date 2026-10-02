#!/usr/bin/env bash
# ============================================================================
# ZRS PVC の状態とデータ継続性を確認する。apply の前後で実行して比較する。
#
#   ./check-zrs.sh before
#   ./check-zrs.sh after
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

tag="${1:-now}"
mkdir -p out
log="out/check-zrs-${tag}.txt"

pv="$(kubectl get pvc zrs-data -o jsonpath='{.spec.volumeName}')"
disk_id="$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}')"
pod="$(kubectl get pod -l app=zrs-writer -o jsonpath='{.items[0].metadata.name}')"

{
  echo "===== check-zrs ${tag} / $(date '+%F %T') ====="
  echo "--- PV ${pv}: nodeAffinity (ZRS ならゾーンに縛られないはず)"
  kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity}' | jq .
  echo "--- マネージドディスク (sku / zones / 作成日時 = 作り直されていないか)"
  az disk show --ids "$disk_id" \
    --query "{name:name,sku:sku.name,zones:zones,timeCreated:timeCreated,state:diskState,managedBy:managedBy}" -o json
  echo "--- Pod の配置"
  kubectl get pod "$pod" -o wide --no-headers
  node="$(kubectl get pod "$pod" -o jsonpath='{.spec.nodeName}')"
  kubectl get node "$node" -L agentpool,topology.kubernetes.io/zone --no-headers
  echo "--- marker (初回起動時に 1 度だけ書く。内容が変わらなければデータは保持されている)"
  kubectl exec "$pod" -- cat /data/marker
  echo "--- 起動履歴 (start 行 = Pod がそのノードで書き込みを開始した時刻)"
  kubectl exec "$pod" -- grep start /data/log | while read -r ts _ n; do
    echo "$(date -u -d "@$ts" '+%F %T') UTC  $n"
  done
  echo "--- 書き込みが 5 秒以上止まった区間 (= Pod 移動による停止時間)"
  kubectl exec "$pod" -- awk '$2!="start"{ if (p && $1-p>=5) printf "%d 秒停止: %s -> %s\n", $1-p, p, $1; p=$1 }' /data/log \
    | while read -r sec _ from _ to; do
        echo "${sec} 秒停止: $(date -u -d "@$from" '+%T') -> $(date -u -d "@$to" '+%T') UTC"
      done
} 2>&1 | tee "$log"
