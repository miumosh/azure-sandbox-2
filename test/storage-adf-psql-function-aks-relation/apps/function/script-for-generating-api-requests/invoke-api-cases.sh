#!/usr/bin/env bash
# Function API のテストケース (cases.json) をワンコマンドで実行するラッパ (テスト用)。
#
# 経路は 2 つ:
#   pod (既定) : AKS の person-id-app Pod の中から **Function を直叩き** (JSON + x-functions-key)。
#                Function は PE 専用かつ snet-pe-func-nsg で AKS サブネットのみ許可のため、
#                ローカル端末からは到達できない。Pod は FUNCTIONS_BASE_URL / FUNCTIONS_KEY を
#                環境変数で持っているので接続情報の受け渡しは不要。
#                run_api_cases.py を stdin で流し込み、cases.json は base64 で引数渡しするため
#                Pod 側に何も配置しない (イメージに curl は無いが python はある)。
#   aks        : AKS の公開 IP へ form で投げる (FastAPI 層込みの E2E)。ローカル端末から実行。
#
# 事前に cases.json を生成しておくこと:
#   python apps/function/script-for-generating-api-requests/generate_api_requests.py --out-dir ./api-requests
#
# 使い方:
#   bash apps/function/script-for-generating-api-requests/invoke-api-cases.sh            # pod 経由 (全件)
#   bash apps/function/script-for-generating-api-requests/invoke-api-cases.sh aks        # AKS 経由 (全件)
#   bash apps/function/script-for-generating-api-requests/invoke-api-cases.sh pod --only F-A01 F-C05
set -euo pipefail

MODE="${1:-pod}"
[ $# -gt 0 ] && shift || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
RUNNER="$HERE/run_api_cases.py"
CASES="${CASES_JSON:-$ROOT/api-requests/cases.json}"

[ -f "$CASES" ] || {
  echo "cases.json が見つかりません: $CASES" >&2
  echo "先に generate_api_requests.py を実行してください" >&2
  exit 1
}

case "$MODE" in
  pod)
    # Pod 内で Function を直叩き (Pod の env にある FUNCTIONS_BASE_URL / FUNCTIONS_KEY を使う)
    B64=$(base64 < "$CASES" | tr -d '\n')
    kubectl exec -i deploy/person-id-app -- \
      python - --mode direct --cases-b64 "$B64" "$@" < "$RUNNER"
    ;;
  aks)
    # AKS の公開 IP へ form で投げる (ローカル実行)
    IP=$(kubectl get svc person-id-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    [ -n "$IP" ] || { echo "person-id-app の EXTERNAL-IP がまだ付与されていません" >&2; exit 1; }
    python3 "$RUNNER" --mode aks --base-url "http://$IP" --cases "$CASES" "$@"
    ;;
  *)
    echo "usage: bash invoke-api-cases.sh [pod|aks] [run_api_cases.py への追加引数]" >&2
    exit 1
    ;;
esac
