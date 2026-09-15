#!/usr/bin/env bash
# 指定した CSV を input/ コンテナへ簡単にアップロードするスクリプト (テスト用)。
#
# - 本番想定では Storage Explorer から SAS で配置するが、テストでは本スクリプトで
#   ワンコマンド投入できる。
# - アップロード先は規定名 input/ciupload39.csv (毎回同名で上書きアップロード)。
#   Storage Account の Blob バージョニングが有効なため、同名でも過去版が版として残り、
#   後から遡れる (どの版がどのテストファイルかは csv/upload-manifest.tsv に記録する)。
#
# 接続情報 (storage account / container / SAS) はすべて Hub の terraform output から取得する
# ため、サブスクリプション ID 等を手で渡す必要はない。SAS は IP 制限付き (allowed_upload_ip)。
#
# 使い方:
#   bash apps/storage/script-for-generating-sample-csv/upload-csv-to-blob.sh ./csv/valid.csv
set -euo pipefail

SRC="${1:?usage: bash upload-csv-to-blob.sh <csv-file>}"
[ -f "$SRC" ] || { echo "file not found: $SRC" >&2; exit 1; }

# リポジトリルート (このスクリプトから 3 階層上) と Hub terraform ディレクトリ
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HUB_TF="$ROOT/terraform/envs/hub-subscription"

ACCT=$(terraform -chdir="$HUB_TF" output -raw storage_account_name)
CONT=$(terraform -chdir="$HUB_TF" output -raw upload_container_name)
SAS=$(terraform -chdir="$HUB_TF" output -raw upload_container_sas_url | cut -d'?' -f2-)

# 規定名 (毎回同名)。バージョニングで過去版が残るため日時はファイル名に付けない。
DEST="input/ciupload39.csv"

az storage blob upload \
  --account-name "$ACCT" \
  --container-name "$CONT" \
  --name "$DEST" \
  --file "$SRC" \
  --sas-token "$SAS" \
  --overwrite --only-show-errors >/dev/null

mkdir -p "$ROOT/csv"
printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$DEST" "$(basename "$SRC")" >> "$ROOT/csv/upload-manifest.tsv"

echo "uploaded: $(basename "$SRC")  ->  ${DEST} (同名上書き / 過去版はバージョニングで保持)"
echo "manifest: csv/upload-manifest.tsv に記録 (日時 -> 元ファイルの対応)"
