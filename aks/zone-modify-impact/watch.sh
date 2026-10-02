#!/usr/bin/env bash
# ============================================================================
# 検証 (4): apply 中の状態を 10 秒おきに記録する。別ターミナルで apply 前に起動し、
# apply 完了後に Ctrl-C で止める。
#
#   ./watch.sh              # out/watch-<時刻>.log に追記
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

rg="$(terraform output -raw resource_group_name)"
cluster="$(terraform output -raw cluster_name)"
mkdir -p out
log="out/watch-$(date +%Y%m%d-%H%M%S).log"
echo "記録先: ${log}"

while true; do
  {
    echo "===== $(date '+%F %T') ====="
    echo "--- az aks nodepool list"
    az aks nodepool list -g "$rg" --cluster-name "$cluster" \
      --query "[].{name:name,zones:join(',',availabilityZones||['-']),count:count,state:provisioningState}" -o tsv 2>&1
    echo "--- nodes"
    kubectl get nodes -L agentpool,topology.kubernetes.io/zone --no-headers 2>&1
    echo "--- pods"
    kubectl get pod -l app=zrs-writer -o wide --no-headers 2>&1
    echo "--- volumeattachments"
    kubectl get volumeattachment --no-headers 2>&1
  } | tee -a "$log"
  sleep 10
done
