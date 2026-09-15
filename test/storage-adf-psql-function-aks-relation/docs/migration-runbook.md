# 適用手順書 (今回の変更を既存環境へ反映する)

今回の変更（CSV ヘッダ対応 / `input/` 化 + バージョニング / `deleted_reason` 廃止 /
ID 取得 API 追加 / AKS→Function を Function キー化 / 一覧系リネーム）を既存環境へ反映する手順。

> **全体の `terraform destroy` は不要。** `terraform apply` がリソース差分を調整する。
> ただし Terraform では扱えない手動ステップ（DB スキーマ・zip 再ビルド・k8s 旧オブジェクト掃除）が要る。
> destroy / apply / psql / kubectl は各自で実行すること（本手順書はコマンドの提示のみ）。

---

## 0. 反映順序（概要）

1. Function zip を再ビルド（関数追加・リネームのため）
2. `terraform apply`（hub → spoke）で Azure リソースを調整
   - hub: Blob バージョニング有効化 / `input/` パス / ADF パイプライン更新
   - spoke: Easy Auth・AAD・UAMI 撤去 / Function キー化 / zip 再デプロイ
3. PostgreSQL スキーマを手動で作り直し（`deleted_reason` 廃止を反映）
4. AKS の旧オブジェクトを掃除し、本人特定アプリ（person-id-app）を適用
5. CSV を `input/ciupload39.csv` に投入して E2E 検証

---

## 1. Function zip 再ビルド

`files/function_app/customer_search/README.md` の手順。リポジトリルートで:

```bash
APP="$(pwd)/terraform/envs/spoke-subscription/files/function_app/customer_search"
OUT="$APP/build/api-$(date +%Y%m%d).zip"   # 依存込み zip を build/ に日付名で出力
SRC="$APP/src"
BUILD="$(mktemp -d)"
cp -r "$SRC"/. "$BUILD"/
pip install --target "$BUILD/.python_packages/lib/site-packages" \
  --only-binary=:all: --platform manylinux2014_x86_64 \
  --python-version 3.13 --implementation cp \
  -r "$SRC/requirements.txt"   # v2 はアプリ単位の単一 requirements.txt
rm -f "$OUT"; ( cd "$BUILD" && zip -qr "$OUT" . ); rm -rf "$BUILD"
```

> ビルドした `api-YYYYMMDD.zip` は、**Hub の踏み台 VM 上から `az storage blob upload --auth-mode login` で
> Storage の `deployments` コンテナへアップロード**する（成果物 Storage は完全閉域=PE のため踏み台 VM 経由）。
> Terraform は zip を upload しない（`func_package_name` で blob 名を参照するだけ）。⚠️ **アップロード → apply の順序厳守**。
> zip アップロード（データ面）は踏み台 VM から、`terraform apply`（コンテナは azapi=ARM）はローカルからも可。

---

## 2. terraform apply（hub → spoke）

```bash
terraform -chdir=terraform/envs/hub-subscription plan    # 差分確認
terraform -chdir=terraform/envs/hub-subscription apply

terraform -chdir=terraform/envs/spoke-subscription plan
terraform -chdir=terraform/envs/spoke-subscription apply
```

apply が自動で行うこと（destroy 不要）:

- **hub**: Storage の `versioning_enabled=true`、`.keep` を `input/.keep` へ、
  ADF データセット（`firstRowAsHeader=true` / `folderPath=input`）・パイプライン（ヘッダ名マッピング・
  `deleted_reason` 除去）・トリガー（`/blobs/input/`）の更新。
- **spoke**: `auth_settings_v2`（Easy Auth）削除、`aad.tf`（AAD アプリ / App Role / SP）削除、
  UAMI `aks_workload` と Federated Credential 削除、Function キー data source 追加、
  Function 用 Storage の完全閉域化（`public_network_access=false` + blob/queue/table PE + 共有キー無効 + MI ロール）、
  踏み台 VM サブネット許可の NSG、`WEBSITE_RUN_FROM_PACKAGE` を `func_package_name`（手動アップロード済み blob 名）へ更新。

> spoke の plan で **削除されるリソース**（azuread_application / service_principal /
> app_role_assignment / user_assigned_identity / federated_identity_credential）が出るのは想定どおり。

---

## 3. PostgreSQL スキーマを作り直す（手動・重要）

`create-tables.sql` は `CREATE TABLE IF NOT EXISTS` のため、**既存テーブルは再実行では作り替わらない**。
今回は (a) `deleted_reason` 列の廃止、(b) `view_prd_table` の廃止、(c) テーブル名の
`customer_info_*` へのリネーム、(d) **landing/error 列を VARCHAR(255) 化**（桁数超過を許容し SQL 検証へ）、
(e) **production/staging の NOT NULL 化**、(f) **name_kana を VARCHAR(50) 化**
を含むため、踏み台 VM から Entra 管理者で接続し、**旧オブジェクトを DROP してから新スキーマを作成**する。

```bash
# 踏み台 VM 上（Bastion 経由）。FQDN は output から。
PSQL_FQDN=$(terraform -chdir=terraform/envs/spoke-subscription output -raw psql_fqdn)
az login --identity --allow-no-subscriptions
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)

# 旧オブジェクトを破棄（view -> tables の順で依存を外す。旧名・新名の両方を IF EXISTS で安全に）
psql "host=$PSQL_FQDN port=5432 dbname=appdb user=<entra-admin-upn> sslmode=require" -c \
  "DROP VIEW IF EXISTS view_prd_table;
   DROP TABLE IF EXISTS stg_table, prd_table, new_prd_table, error_table;
   DROP TABLE IF EXISTS customer_info_landing, customer_info_staging, customer_info_building, customer_info_production, customer_info_error;"

# 新スキーマ（customer_info_* / 4 カラム / ID 取得用インデックス）を作成
psql "host=$PSQL_FQDN port=5432 dbname=appdb user=<entra-admin-upn> sslmode=require" \
  -f apps/psql/sql-for-setting-up-database/create-tables.sql
```

> データを保持したい場合は DROP の代わりに `ALTER TABLE <旧名> RENAME TO <新名>;` ＋
> `ALTER TABLE <t> DROP COLUMN deleted_reason;`、view は単純に `DROP VIEW` で対応する。
> AAD ロール（`ci00-func` 等）が未作成の環境では先に `create-aad-roles.sql` を postgres DB で実行。

---

## 4. AKS: 旧オブジェクト掃除 → 新マニフェスト適用

リネームのため `kubectl apply` では旧 `aks-client-app` 等が残る。先に削除する。

```bash
# 旧オブジェクトの掃除（存在すれば）
kubectl delete deploy,svc,sa aks-client-app aks-client-sa --ignore-not-found
# 一覧アプリは廃止。過去にデプロイ済みなら削除する
kubectl delete deploy,svc persons-list-app --ignore-not-found
kubectl delete secret persons-list-func-key --ignore-not-found

# 値を取得
BASE_URL=$(terraform -chdir=terraform/envs/spoke-subscription output -raw function_app_base_url)
FUNCTIONS_KEY=$(terraform -chdir=terraform/envs/spoke-subscription output -raw function_default_key)
ACR_LOGIN=$(terraform -chdir=terraform/envs/hub-subscription output -raw acr_login_server)
export BASE_URL FUNCTIONS_KEY

# 本人特定アプリのイメージを ACR でビルド（public 一時開放は README 手順参照）
IMAGE="$ACR_LOGIN/person-id-app:latest" \
  envsubst < apps/aks/app-for-getting-person-id/k8s/deployment.yaml | kubectl apply -f -

kubectl get svc person-id-app -w
```

---

## 5. E2E 検証

```bash
# サンプル CSV（ヘッダ付き・4 カラム）を生成して input/ciupload39.csv へ投入
python apps/storage/script-for-generating-sample-csv/generate_sample_csv.py --rows 100000 --out-dir ./csv
bash apps/storage/script-for-generating-sample-csv/upload-csv-to-blob.sh ./csv/valid.csv
```

確認ポイント:

1. ADF Studio → Monitor で `pl_csv_ingest` が **Succeeded**。`InputCSV` がヘッダ名で
   マッピングし、`customer_info_landing` 件数が「CSV 行数 −1（ヘッダ分）」になる。
2. `customer_info_production` が更新される（`deleted_reason` 列は無い）。
3. 本人特定アプリ（`person-id-app`）で name_kana/birth_ymd/cellular_phone_no を入力 → 一致する policy_no が返る。
5. 同名 `input/ciupload39.csv` を再投入 → Storage のバージョン一覧に過去版が残る
   （Storage Explorer / `az storage blob list --include v`）。

### Function キーでの手動確認（任意・踏み台等から）

```bash
FUNCTIONS_KEY=$(terraform -chdir=terraform/envs/spoke-subscription output -raw function_default_key)
BASE_URL=$(terraform -chdir=terraform/envs/spoke-subscription output -raw function_app_base_url)
# ID 取得 API（PII は body）
curl -s -X POST "$BASE_URL/api/customers/search" -H "x-functions-key: $FUNCTIONS_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name_kana":"タムラタロウ","birth_ymd":"19721106","cellular_phone_no":"692-5834-2921"}'
```

> Function は Private Endpoint 経由のみ。手動 curl は VNet 内（踏み台等、privatelink DNS 解決可）から実行する。
