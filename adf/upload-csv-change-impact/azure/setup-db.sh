#!/usr/bin/env bash
# 本番の create-tables.sql で appdb にテーブルを作成する (末尾の AAD ロールへの GRANT は除く)。
# psql はローカルに無くてもよいよう postgres イメージの psql を docker で使う。
# パスワードは環境変数 PGPASSWORD、未設定なら入力を求める。
set -euo pipefail
cd "$(dirname "$0")"

SQL=../../../test/storage-adf-psql-function-aks-relation/apps/psql/sql-for-setting-up-database/create-tables.sql
FQDN=$(terraform output -raw psql_fqdn)
USER=$(terraform output -raw psql_admin_login)
DB=$(terraform output -raw psql_database)

if [[ -z "${PGPASSWORD:-}" ]]; then
  read -rsp "PostgreSQL admin password: " PGPASSWORD; echo
fi

sed '/-- AAD ロールへの最小権限付与/,$d' "$SQL" |
  docker run --rm -i -e PGPASSWORD="$PGPASSWORD" postgres:16-alpine \
    psql "host=$FQDN port=5432 dbname=$DB user=$USER sslmode=require" -X -v ON_ERROR_STOP=1 -f -

echo "tables created on $FQDN/$DB"
