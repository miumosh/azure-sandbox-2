# storage-adf-psql-function-aks-relation

`.claude/architecture.md` に基づき、Hub / Spoke 2 サブスクリプション構成の
Azure リソースを Terraform + アプリケーションコードで構築する検証プロジェクトです。

```
 Hub Subscription (ci00-hub-subscription)          Spoke Subscription (ci00-spoke-subscription)
 ┌─────────────────────────────────────┐           ┌─────────────────────────────────────────────┐
 │ [Storage Explorer]                  │           │                                             │
 │   │ SAS + IP allow                  │           │                                             │
 │   ▼                                 │           │                                             │
 │ [Storage Account] ──BlobEvent──> [Data Factory] │                                             │
 │   ▲ (Managed PE: blob)              │   │ Managed PE: postgresqlServer (cross-sub)            │
 │                                     │   └────────────────────────> [PostgreSQL] <── PE ───────│
 │ [Jumpbox VM] (public IP/SSH) ─psql──┼─────────(VNet peering)──────────↑                       │
 │                                     │           │                     │ (VNet Integration)    │
 │        Hub VNet (10.39.0.0/16)      │<─peering─>│                  [Azure Functions]          │
 └─────────────────────────────────────┘           │                     ↑ (PE)                  │
                                                   │                  [AKS Pod (FastAPI Web UI)] │
                                                   │     Spoke VNet (10.40.0.0/16)               │
                                                   └─────────────────────────────────────────────┘
```

## ディレクトリ構成

```
.
├── .claude/architecture.md            # アーキテクチャ設計書
├── apps/                      # 各リソースで動くアプリ / スクリプト
│   ├── aks/
│   │   └── app-for-getting-person-id/     # 本人特定で id 取得 (POST /api/customers/search) を呼ぶ FastAPI クライアント
│   │       ├── main.py
│   │       ├── requirements.txt
│   │       ├── Dockerfile
│   │       └── k8s/deployment.yaml        # Secret(Function キー) + Deployment + Service
│   ├── psql/sql-for-setting-up-database/
│   │   ├── create-database.sql       # 通常不要 (Terraform が appdb 作成)
│   │   ├── create-aad-roles.sql      # postgres DB で AAD ロール作成
│   │   └── create-tables.sql         # appdb でテーブル + 権限付与
│   ├── storage/script-for-generating-sample-csv/
│   │   ├── generate_sample_csv.py     # 正常系サンプル CSV 生成 (./csv/valid.csv)
│   │   ├── generate_invalid_csv.py    # フォーマット違反テスト CSV を種別ごとに生成
│   │   ├── generate_scenario_csv.py   # 1 ファイル = 1 観点のシナリオ CSV 生成 (手動テスト経路1 用)
│   │   ├── simulate_validation.py     # validation.sql を再現し投入前に期待値を算出
│   │   ├── upload-csv-to-blob.sh      # ./csv の CSV を input/ciupload39.csv へ投入 (同名上書き / 版で履歴)
│   │   └── requirements.txt
│   ├── function/script-for-generating-api-requests/
│   │   ├── generate_api_requests.py   # 本人特定 API のリクエスト JSON + 期待値 (cases.json) を生成
│   │   ├── run_api_cases.py           # cases.json を投げて期待値と突合 (標準ライブラリのみ = Pod 内で動く)
│   │   └── invoke-api-cases.sh        # Pod 経由 (Function 直叩き) / AKS 公開 IP 経由 でワンコマンド実行
│   └── excel/
│       ├── generate_parameter_sheet.py  # 詳細設計書(パラメータシート) xlsx を生成
│       └── requirements.txt             # openpyxl
├── terraform/
│   ├── modules/                       # 再利用モジュール (Hub/Spoke 両 env から呼ぶ)
│   │   ├── network/                   # VNet+subnets+DNS zone+link+peering+NSG
│   │   ├── private_endpoint/          # 汎用 Private Endpoint
│   │   ├── storage/                   # アップロード/アーカイブ Storage
│   │   ├── container_registry/        # Premium ACR + AcrPull
│   │   ├── jumpbox/                   # public IP + SSH の踏み台 VM
│   │   ├── data_factory/             # ADF (Managed VNet/PE + 取込パイプライン)
│   │   ├── aks/                       # AKS クラスター
│   │   ├── postgresql/                # PostgreSQL Flexible Server
│   │   └── function_app/              # Function App + run-from-package
│   └── envs/                          # env 単位の root (main.tf + locals + module 呼び出し)
│       ├── hub-subscription/          # Storage / ADF / 踏み台VM / ACR / Hub VNet
│       │   ├── main.tf                # RG + module 呼び出し + PE + outputs
│       │   ├── locals.tf              # 構成値 (object。local.storage_accounts.main 等)
│       │   ├── variables.tf           # 機微情報 / cross-sub 参照のみ
│       │   ├── providers.tf
│       │   ├── terraform.tfvars.sample
│       │   └── files/adf_pipeline/customer_info_registration/    # pipeline.json + script_activity.sql (検証 SQL)
│       └── spoke-subscription/        # PostgreSQL / Functions / AKS / Spoke VNet
│           ├── main.tf                # RG + Log Analytics + module 呼び出し + PE + outputs
│           ├── locals.tf              # 構成値 (object。local.aks_clusters.main 等)
│           ├── variables.tf           # 機微情報 / cross-sub 参照のみ
│           ├── providers.tf
│           ├── terraform.tfvars.sample
│           └── files/function_app/customer_search/    # Function アプリ (本人特定 API)
│               ├── README.md            # zip ビルド & 手動アップロード手順
│               ├── src/                 # zip 化前のソース一式 (function_app.py 等)
│               └── build/               # 依存込み zip の置き場 (.keep のみ追跡。zip は gitignore)
│                                        # zip は踏み台 VM から Storage へ手動アップロード (TF は upload しない)
├── docs/                               # ドキュメント
│   ├── pipeline.md                     # ADF 取り込みパイプライン（構成・検証・Success/Error アーカイブ）
│   ├── auth.md                         # 認証・権限の整理
│   ├── network.md                      # ネットワーク制御・閉域化の整理
│   ├── troubleshooting.md              # デプロイ時のハマりどころと対処
│   ├── python.md                       # Azure Functions Python v2 モデルのナレッジ
│   ├── api-customer-search.md          # 本人特定 API (customer-search) 仕様
│   ├── test.md                         # 異常系テストのカタログと実測結果
│   └── migration-runbook.md            # 既存環境への適用手順
├── test/                               # 手動テスト手順 (経路別・網羅パターン表)
│   ├── README.md                       # 索引 / 前提 / 共通の環境変数 / 確認手段の制約
│   ├── 01-storage-csv.md               # 経路1: Storage に CSV を投入して結果を確認
│   └── 02-function-api.md              # 経路2: Function API にリクエストを投入して結果を確認
├── excel/
│   └── parameter-sheet.xlsx           # 詳細設計書(パラメータシート)。generate_parameter_sheet.py で再生成
├── .gitignore
└── README.md
```

## Hub / Spoke と VNet について

本構成では **Hub VNet と
Spoke VNet を VNet ピアリングで接続**し、インターネットを経由しないプライベート
通信を実現することで要件を満たしています。

- Hub VNet (`10.39.0.0/16`): 踏み台 VM (public IP/SSH) / Storage PE / ACR PE
- Spoke VNet (`10.40.0.0/16`): AKS / PostgreSQL PE / Functions PE + VNet 統合
  - AKS は ACR の Private DNS（`privatelink.azurecr.io`）リンク + ピアリング経由で Hub の ACR PE を pull

ADF は Managed VNet を使うため専用サブネットを持たず、Managed Private Endpoint で
Hub の Storage と Spoke の PostgreSQL (cross-subscription) に接続します。

## 前提条件: サブスクリプションのクォータ / VM サイズ

新規・制限付きサブスクリプションでは既定クォータが 0 のことがあり、apply 前に
以下を確認・申請しておく必要があります（検証時に実際に詰まったポイント）。

- **Azure Functions (Elastic Premium) のクォータ**:
  Functions は VNet 統合 + Private Endpoint のため **EP1（Elastic Premium）** プランを使う。
  App Service のクォータが 0 だと `Operation cannot be completed without additional quota`
  （`Total VMs: 0`）で失敗する。
  → Portal の **「使用量 + クォータ」→ App Service → Japan East** で、**`EP1 VMs`** と
  **`Total Regional VMs`** を **3 程度**に増加申請する（小さい値は自動承認されやすい）。
- **AKS / VM のサイズ可用性**:
  サブスクリプション/リージョンによって使えるサイズが異なる。`Standard_DS2_v2` が
  不可で apply が失敗する場合は、許可リスト内のサイズ（既定は `Standard_D2s_v3`）を
  `aks_node_size` に指定する。`az vm list-skus -l japaneast` 等で確認できる。
  踏み台 VM（Hub の `jumpboxes.main.vm_size`、既定 `Standard_B1s`）も同様に不可なら変更する。

## デプロイ手順

cross-subscription のピアリングは相互参照になるため、以下の順序で apply します。

### 1. Spoke を apply (Hub 参照なしで先行)

```bash
cd terraform/envs/spoke-subscription
cp terraform.tfvars.sample terraform.tfvars
# subscription_id / psql_admin_password などを設定 (hub_vnet_id は空のまま)
terraform init
terraform apply
```

### 2. Hub を apply (Spoke の output を反映)

```bash
cd ../hub-subscription
cp terraform.tfvars.sample terraform.tfvars
# Spoke の output を tfvars に貼り付ける:
#   spoke_vnet_id    = $(terraform -chdir=../spoke-subscription output -raw spoke_vnet_id)
#   psql_server_id   = $(terraform -chdir=../spoke-subscription output -raw psql_server_id)
#   psql_server_name = $(terraform -chdir=../spoke-subscription output -raw psql_server_name)
#   psql_fqdn        = $(terraform -chdir=../spoke-subscription output -raw psql_fqdn)
# allowed_upload_ip / jumpbox_admin_password なども設定
terraform init
terraform apply
```

### 3. Spoke を再 apply (Hub VNet とのピアリング / DNS リンクを追加)

```bash
cd ../spoke-subscription
# hub_vnet_id を tfvars に反映:
#   hub_vnet_id = $(terraform -chdir=../hub-subscription output -raw hub_vnet_id)
terraform apply
```

これで Hub ⇔ Spoke の双方向ピアリングと、踏み台 VM から PostgreSQL を名前解決
するための Private DNS リンクが完成します。

### 3-b. ADF の Managed Private Endpoint を承認 (Storage / PostgreSQL)

ADF の Managed Private Endpoint（`mpe-storage-blob` / `mpe-psql`）は、Terraform が
接続**リクエストを作成するだけ**で、ターゲット側は **Pending（保留）** になります。
承認するまで ADF からの Private 通信は通りません（特に cross-subscription の
PostgreSQL は手動承認必須）。Hub apply（手順 2）後に一度だけ承認します。

承認対象は **`status` が `Pending` の接続 = ADF の Managed PE** です（顧客作成の inbound PE は
自動承認で `Approved` のため、Pending を選べば確実に ADF のものになります）。

```bash
# --- 変数定義（最初にまとめて設定。サブスク ID も output から取得） ---
HUB_SUB=$(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)
SPOKE_SUB=$(terraform -chdir=terraform/envs/spoke-subscription output -raw subscription_id)
HUB_RG=$(terraform -chdir=terraform/envs/hub-subscription output -raw resource_group_name)
SPOKE_RG=$(terraform -chdir=terraform/envs/spoke-subscription output -raw resource_group_name)
STORAGE_NAME=$(terraform -chdir=terraform/envs/hub-subscription output -raw storage_account_name)
PG_NAME=$(terraform -chdir=terraform/envs/spoke-subscription output -raw psql_server_name)
```

```bash
# --- リソース ID を取得 ---
STORAGE_ID=$(az storage account show --name "$STORAGE_NAME" --resource-group "$HUB_RG" --subscription "$HUB_SUB" --query id -o tsv)
PG_ID=$(az postgres flexible-server show --name "$PG_NAME" --resource-group "$SPOKE_RG" --subscription "$SPOKE_SUB" --query id -o tsv)
```

```bash
# --- Storage: Pending 接続を一覧で確認 ---
az network private-endpoint-connection list --id "$STORAGE_ID" --subscription "$HUB_SUB" \
  --query "[].{name:name, status:properties.privateLinkServiceConnectionState.status, id:id}" -o table
```

```bash
# --- Storage: Pending の接続 ID を取得 ---
STORAGE_CONN_ID=$(az network private-endpoint-connection list --id "$STORAGE_ID" --subscription "$HUB_SUB" \
  --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].id | [0]" -o tsv)
```

```bash
# --- Storage: 承認 ---
az network private-endpoint-connection approve --id "$STORAGE_CONN_ID" --subscription "$HUB_SUB" \
  --description "Approved ADF mpe-storage-blob"
```

```bash
# --- PostgreSQL: Pending 接続を一覧で確認 ---
az network private-endpoint-connection list --id "$PG_ID" --subscription "$SPOKE_SUB" \
  --query "[].{name:name, status:properties.privateLinkServiceConnectionState.status, id:id}" -o table
```

```bash
# --- PostgreSQL: Pending の接続 ID を取得 ---
PG_CONN_ID=$(az network private-endpoint-connection list --id "$PG_ID" --subscription "$SPOKE_SUB" \
  --query "[?properties.privateLinkServiceConnectionState.status=='Pending'].id | [0]" -o tsv)
```

```bash
# --- PostgreSQL: 承認 ---
az network private-endpoint-connection approve --id "$PG_CONN_ID" --subscription "$SPOKE_SUB" \
  --description "Approved ADF mpe-psql"
```

> 承認には対象リソースに対する `Microsoft.Network/privateEndpointConnections` の
> 承認アクション権限（Owner / Contributor 相当）が必要です。
> Azure Portal の各リソース「ネットワーク > プライベートエンドポイント接続」からも承認できます。
> 顧客作成の PE（Storage/PSQL/Functions の inbound PE）は Terraform が
> `is_manual_connection = false` で自動承認するため、手動承認は ADF の Managed PE のみ対象です。

### 4. PostgreSQL のデータベース / テーブルを作成 (踏み台 VM 経由)

PostgreSQL（Flexible Server）は Private Endpoint のみで公開されているため、
Hub の踏み台 VM へ public IP 経由で SSH 接続してから psql を実行します
（接続元は NSG で `allowed_upload_ip` のみ許可）。
`create-tables.sql` の AAD ロール作成（`pgaadauth_create_principal`）は
**Entra ID 管理者として AAD 認証で接続したセッション**でのみ実行できるため、
bootstrap は Entra 管理者（tfvars の `entra_admin_*`）で行います。

> **テナント注意**: 踏み台 VM 上の `az login` は PSQL の Entra 管理者テナント
> （Spoke サブスクのテナント）を `--tenant` で必ず明示します。複数サブスク/テナントの
> 権限を持つアカウントだと既定テナントがずれ、別テナント向けトークンを取得して
> `FATAL: The access token isn't valid for this server's tenant` になります。

```bash
# --- 変数（ローカル端末 / リポジトリルートで実行） ---
HUB_SUB=$(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)
HUB_RG=$(terraform -chdir=terraform/envs/hub-subscription output -raw resource_group_name)
JUMPBOX=$(terraform -chdir=terraform/envs/hub-subscription output -raw jumpbox_name)
JUMPBOX_IP=$(terraform -chdir=terraform/envs/hub-subscription output -raw jumpbox_public_ip)
# 踏み台 VM 上で使う値（あらかじめ控えておく）
PSQL_FQDN=$(terraform -chdir=terraform/envs/spoke-subscription output -raw psql_fqdn)
ADMIN_UPN="<entra_admin_principal_name>"   # tfvars に設定した UPN
SPOKE_SUB=$(terraform -chdir=terraform/envs/spoke-subscription output -raw subscription_id)
PSQL_TENANT=$(az account show --subscription "$SPOKE_SUB" --query tenantId -o tsv)  # PSQL の Entra 管理者テナント（このテナントのトークンが必要）

# 踏み台へ持ち込む値を表示（控えておく）
echo "PSQL_FQDN=$PSQL_FQDN"
echo "ADMIN_UPN=$ADMIN_UPN"
echo "PSQL_TENANT=$PSQL_TENANT"
```

> 踏み台 VM は public IP を持ち、SSH(22/TCP) は NSG で `allowed_upload_ip` のみ許可。
> 認証はパスワード（`jumpbox_admin_password`）。ファイル転送は `scp` が使えます。

```bash
# --- ローカルから踏み台 VM へ SSH（public IP・パスワード認証） ---
ssh azureuser@"$JUMPBOX_IP"
# ファイル転送はそのまま scp:
#   scp ./build/api-YYYYMMDD.zip azureuser@"$JUMPBOX_IP":~/
```

```bash
# --- 踏み台 VM 上: 変数（ローカルで控えた値を貼り付け） ---
PSQL_FQDN="<psql_fqdn>"          # 上のローカル変数 $PSQL_FQDN の値
ADMIN_UPN="<entra-admin-upn>"    # tfvars の entra_admin_principal_name
PSQL_TENANT="<psql_tenant_id>"   # 上のローカル変数 $PSQL_TENANT の値（例: <TENANT_ID>）
```

```bash
# --- 踏み台 VM 上: Entra 管理者でログインしてトークン取得 ---
# 注意: 複数サブスク/テナントの権限を持つアカウントだと az login が別テナントを
#       既定選択し、別テナント向けトークンを取得してしまう（FATAL: ...isn't valid
#       for this server's tenant）。PSQL の管理者テナントを必ず明示する。
az login --tenant "$PSQL_TENANT"          # PostgreSQL の AAD 管理者アカウントでこのテナントへ
# 代替: 正テナント配下のサブスクに切り替えても可（どちらか一方で十分）
#   az account set --subscription "$SPOKE_SUB"
az account show --query tenantId -o tsv   # 表示値が $PSQL_TENANT と一致することを確認
export PGPASSWORD=$(az account get-access-token \
  --resource-type oss-rdbms --tenant "$PSQL_TENANT" --query accessToken -o tsv)
```

各 MI の object_id を取得して `create-aad-roles.sql` のプレースホルダ（`<ADF_OID>` /
`<FUNC_OID>` / `<JUMP_OID>`）を実値に置換しておきます（ローカルで取得し、踏み台へ持ち込み）:

```bash
terraform -chdir=terraform/envs/hub-subscription  output -raw data_factory_principal_id  # = ADF_OID
terraform -chdir=terraform/envs/spoke-subscription output -raw function_principal_id      # = FUNC_OID
terraform -chdir=terraform/envs/hub-subscription  output -raw jumpbox_principal_id        # = JUMP_OID
```

```bash
# --- 踏み台 VM 上(1): AAD ロール作成は postgres DB で実行 ---
# pgaadauth_* 関数は postgres DB にのみ存在する。ロールはクラスタ共有なので appdb からも見える。
psql "host=$PSQL_FQDN port=5432 dbname=postgres user=$ADMIN_UPN sslmode=require" -f create-aad-roles.sql
```

```bash
# --- 踏み台 VM 上(2): テーブル + 権限付与は appdb で実行 ---
# appdb は Terraform 作成済み。create-database.sql は通常不要
# （実行すると "database appdb already exists"）。create-tables.sql はロール作成後に実行する。
psql "host=$PSQL_FQDN port=5432 dbname=appdb user=$ADMIN_UPN sslmode=require" -f create-tables.sql
```

> `create-aad-roles.sql`（postgres DB）が ADF（`ci00-adf`）/ Function（`ci00-func`）/
> 踏み台（`ci00-jumpbox`）の MI を AAD ロールとして作成（`_with_oid` で Graph 依存回避）。
> `create-tables.sql`（appdb）がテーブル + 権限を付与し、ADF にはテーブル所有権、Function / 踏み台
> には参照のみを与えます。SQL 認証（`psqladmin`）は break-glass 用に残しています。

#### 日常の psql 接続は踏み台 MI でパスワードレス

ブートストラップ（上記・ロール作成を含む DDL）は **Entra 管理者＝人間**で一度だけ実施します。
以降のデータ確認などの**日常接続**は、踏み台 VM の **マネージドID**（`ci00-jumpbox`、参照のみ）で
パスワードレスに行えます（踏み台 MI は Entra 管理者ではなく最小権限の通常ロール）。

```bash
# --- 踏み台 VM 上: 変数 ---
PSQL_FQDN="<psql_fqdn>"   # terraform -chdir=terraform/envs/spoke-subscription output -raw psql_fqdn
```

```bash
# --- 踏み台 VM 上: VM の MI でログインしてトークン取得 → 参照クエリ ---
az login --identity --allow-no-subscriptions
export PGPASSWORD=$(az account get-access-token \
  --resource-type oss-rdbms --query accessToken -o tsv)
psql "host=$PSQL_FQDN port=5432 dbname=appdb user=ci00-jumpbox sslmode=require" \
     -c "SELECT count(*) FROM customer_info_production;"
```

### 5. Azure Functions をデプロイ（run-from-package / 閉域維持）

ソースは `terraform/envs/spoke-subscription/files/function_app/customer_search/src/`（本人特定 API の Function App）。
**依存込みの zip をビルド**し、**Hub の踏み台 VM から `az storage blob upload` で Storage の `deployments` コンテナへアップロード**、
`func_package_name` を更新して `terraform apply` すると `WEBSITE_RUN_FROM_PACKAGE` が更新され、
**設定変更で Function が自動再起動**して反映されます（SCM 不使用＝`public_network_access=false` の閉域のまま）。
**Terraform は zip を upload しません**（blob 名を変数で参照）。成果物 Storage は **完全閉域（blob/queue/table PE）+ 共有キー無効 + Entra RBAC**、
Function は **MI + PE** で読みます。CI/CD は採用しません（恒久・手動。**zip アップロードは踏み台 VM／`apply` はローカル可**）。
コードは **Python v2 モデル（デコレーター方式）**で、AKS → Function の認証は **Function キー方式**
（route の `auth_level=FUNCTION`）。ナレッジは [`docs/python.md`](docs/python.md)、詳細手順は
[`files/.../function_app/customer_search/README.md`](terraform/envs/spoke-subscription/files/function_app/customer_search/README.md)。

```bash
# (1) zip をビルド（踏み台 VM 上 or ローカル。pip と zip が必要）。依存込みで build/ に日付名で出力。
APP="$(pwd)/terraform/envs/spoke-subscription/files/function_app/customer_search"
OUT="$APP/build/api-$(date +%Y%m%d).zip"
SRC="$APP/src"
BUILD="$(mktemp -d)"
cp -r "$SRC"/. "$BUILD"/
pip install --target "$BUILD/.python_packages/lib/site-packages" \
  --only-binary=:all: --platform manylinux2014_x86_64 \
  --python-version 3.13 --implementation cp \
  -r "$SRC/requirements.txt"
rm -f "$OUT"; ( cd "$BUILD" && zip -qr "$OUT" . ); rm -rf "$BUILD"
```

```bash
# (2) ローカルでビルドした zip を踏み台 VM へ scp で投入（public IP・パスワード認証＝jumpbox_admin_password）。
#     踏み台 VM 上で直接ビルドした場合は転送不要で (3) へ。SSH 22 が通れば scp も同じ NSG 許可で通る。
JUMPBOX_IP=$(terraform -chdir=terraform/envs/hub-subscription output -raw jumpbox_public_ip)
scp "$OUT" azureuser@"$JUMPBOX_IP":~/   # → 踏み台の ~/api-YYYYMMDD.zip に配置
```

```bash
# (3) 踏み台 VM 上で az login 後、deployments コンテナへアップロード（Entra RBAC）。
#     --file は踏み台上の zip パス（scp 先 ~/ もしくは踏み台でビルドした build/ 配下）。
az storage blob upload --auth-mode login --account-name <funcst名> \
  --container-name deployments --name api-YYYYMMDD.zip \
  --file ~/api-YYYYMMDD.zip
# (4) blob 名を指定して apply（設定変更で自動再起動。⚠️ 先にアップロード→後で apply の順序厳守）
terraform -chdir=terraform/envs/spoke-subscription apply -var 'func_package_name=api-YYYYMMDD.zip'
```

- 依存は `--platform manylinux2014_x86_64 --python-version 3.13 --only-binary=:all:` で
  Linux/cp313 wheel を取得するため**ローカルの Python バージョンに依存しません**（`pip` と `zip` が必要）。
- **Blob アップロードだけでは反映されません**（`func_package_name` 更新 + apply が必須）。ロールバックは前の日付 zip 名に戻して apply。
- 成果物 Storage は完全閉域です。**zip アップロード（データ面）は踏み台 VM から**、**`terraform apply`（azapi のコントロールプレーン）はローカルからも可**。

#### zip アップロードの権限とアクセス経路（L4 / L7）

zip を、**Hub の踏み台 VM（public IP へ SSH）** から Spoke の `deployments` コンテナへ
アップロードする経路は、L4（ネットワーク）と L7（認可）の二段で閉域成立しています。
zip は踏み台 VM 上で `pip`（cloud-init で導入済み）でビルドするか、ローカルでビルドして `scp` で踏み台へ転送します。

- **L4（ネットワーク到達性）**
  - Storage PE サブネット `snet-pe-stfunc` の NSG が、Hub 踏み台サブネット `10.39.2.0/24` からの **inbound 443 のみ許可**
    （`Allow-Jumpbox-to-StPE-443`）。他の VNet からの inbound は Deny。
  - **DNS 解決も必須**: `privatelink.blob.core.windows.net` ゾーンを **Hub VNet にもリンク**（`hub_peering_enabled` 時）。
    これで踏み台 VM が `<funcst>.blob.core.windows.net` を **Blob PE のプライベート IP** に解決できる。
- **L7（認可）**
  - Storage は `public_network_access=false` + `shared_access_key_enabled=false` のため **Entra RBAC のみ**。
  - 踏み台 VM 上で自分の Entra ユーザーで `az login` →
    `az storage blob upload --auth-mode login` でアップロード。
  - 認可は **Storage アカウント側**が `Storage Blob Data Contributor`（`deployments` コンテナ scope）で評価する。
    **PE はあくまでプライベート経路**で、RBAC を判定するのは PE ではなく Storage。
  - ロールは **ユーザー本人**に付与する（VM の MI は使わない）。`uploader_principal_ids` に自分の objectId を設定する。

> 想定アーキとの齟齬: 基本認識（L4＝VM サブネット許可 / L7＝ユーザーのロールで PE 経由 Blob へアップロード）は正しい。
> 追加で押さえる点は **Blob privatelink ゾーンの Hub リンク（DNS 解決）** が必要なことだけ。

```bash
# (a) 自分の Entra objectId を取得
az ad signed-in-user show --query id -o tsv
# (b) spoke の terraform.tfvars に設定（gitignore 対象のローカル値）
#   uploader_principal_ids = ["<上で得た objectId>"]
# (c) apply でロール付与（Storage Blob Data Contributor @ deployments コンテナ）
terraform -chdir=terraform/envs/spoke-subscription apply
```

#### Function / SCM / Function 用 Storage の閉域化状況

| 対象 | 状態 | 根拠 |
|---|---|---|
| Function 本体（サイト） | ✅ 閉域 | `public_network_access=false`、PE `subresource=["sites"]`、VNet 統合、`ip_restriction_default_action="Deny"`、`https_only`、FTPS 無効 |
| SCM / Kudu | ✅ 閉域 | `["sites"]` PE が web と scm の両方をカバー。公開アクセス無効 |
| Function 用 Storage：blob / queue / table | ✅ 閉域 | 各 PE ＋ DNS ゾーン ＋ MI ロール。`public_network_access=false` + `shared_access_key_enabled=false`（RBAC のみ） |
| Function 用 Storage：file | ⚠️ 未整備 | `file` PE / `privatelink.file.core.windows.net` ゾーン / File 系ロールなし |

`file` 未整備が実害かは「Azure Files のコンテンツ共有を使う構成か」次第。本構成は
**EP1（Elastic Premium）** + **run-from-package（blob・MI 読み取り）** で、`WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` /
`WEBSITE_CONTENTSHARE` は未設定。`shared_access_key_enabled=false` のため従来型のコンテンツ共有接続文字列は
そもそも設定できず、**Files を使わない前提**の設計。EP プランでこれが破綻なく動くかは実挙動で確認する。

```bash
# 1. Files 系設定が自動付与されていないか（出れば Files 依存）
az functionapp config appsettings list -g ci00-spoke-rg -n ci00-func -o table
# 2. ファイル共有が作られていないか（存在すれば Files 使用）
az storage share-rm list --storage-account <funcst名> -g ci00-spoke-rg -o table
# 3. ホストが健全か（空/エラーなら content share マウント失敗の疑い）
az functionapp show -g ci00-spoke-rg -n ci00-func --query state -o tsv
az functionapp function list -g ci00-spoke-rg -n ci00-func -o table
# 4. 起動エラー: Application Insights or ポータルの Diagnose and solve problems で
#    "Azure Files" / "content share" / "Host.Startup" 系エラーを確認
# 5. 機能テスト: 踏み台 VM(SSH) or AKS Pod から Function の private FQDN を curl
```

判定: 1・2 が無し かつ 3 で関数ロード かつ 5 で応答 → **Files 不要・現状で完全閉域**。
1 が有り / 3 で失敗 / 4 に Files 起因エラー → **file PE + DNS ゾーン + ロールを追加**して完全閉域化する。

### 6. AKS にクライアントアプリをデプロイ

イメージは **Hub の ACR（Private / Premium + PE）** に置き、AKS は **AcrPull(RBAC) + PE 経由**で
閉域 pull します（`acr.tf`）。ACR は cross-sub で AKS の kubelet ID に AcrPull を付与するため、
**Hub apply の tfvars に `aks_kubelet_object_id`（spoke output）** を設定しておきます。

```bash
# --- 変数（リポジトリルートで取得。サブスク ID も output から） ---
HUB_SUB=$(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)
SPOKE_SUB=$(terraform -chdir=terraform/envs/spoke-subscription output -raw subscription_id)
HUB_RG=$(terraform -chdir=terraform/envs/hub-subscription output -raw resource_group_name)
SPOKE_RG=$(terraform -chdir=terraform/envs/spoke-subscription output -raw resource_group_name)
AKS=$(terraform -chdir=terraform/envs/spoke-subscription output -raw aks_cluster_name)
BASE_URL=$(terraform -chdir=terraform/envs/spoke-subscription output -raw function_app_base_url)
FUNCTIONS_KEY=$(terraform -chdir=terraform/envs/spoke-subscription output -raw function_default_key)  # x-functions-key 用
ACR=$(terraform -chdir=terraform/envs/hub-subscription output -raw acr_name)
ACR_LOGIN=$(terraform -chdir=terraform/envs/hub-subscription output -raw acr_login_server)
```

イメージの build & push は ACR が閉域のため、**push 時だけ ACR の public を一時開放**します
（pull は常時 PE 経由なので影響なし）。ローカル docker 不要の `az acr build`（クラウドビルド）を使います。

```bash
# (a) push 用に一時開放: Hub tfvars で acr_public_network_access_enabled = true → apply
terraform -chdir=terraform/envs/hub-subscription apply

# (b) ACR でイメージをビルド & push（ビルドコンテキスト = アプリのディレクトリ）
az acr build --registry "$ACR" --image person-id-app:latest \
  apps/aks/app-for-getting-person-id --subscription "$HUB_SUB"

# (c) 閉域へ戻す: acr_public_network_access_enabled = false → apply
terraform -chdir=terraform/envs/hub-subscription apply
```

```bash
# --- kubeconfig 取得 ---
az aks get-credentials --resource-group "$SPOKE_RG" --name "$AKS" --subscription "$SPOKE_SUB"
```

呼び出し認証は **Function キー方式**。Function キーは Secret に格納し Pod へ環境変数で渡します
（`x-functions-key` ヘッダで Function を呼ぶ。Workload Identity / AAD は不使用）。
マニフェストを envsubst で置換して適用します。

```bash
# --- 本人特定アプリ (person-id-app) を適用 ---
export BASE_URL FUNCTIONS_KEY   # 上で取得済みの値
IMAGE="$ACR_LOGIN/person-id-app:latest" \
  envsubst < apps/aks/app-for-getting-person-id/k8s/deployment.yaml | kubectl apply -f -
```

```bash
# --- 公開 IP を確認してブラウザでアクセス ---
kubectl get svc person-id-app -w   # EXTERNAL-IP が付与されたらアクセス
```

- Pod は Secret に格納した Function キーを `FUNCTIONS_KEY` 環境変数で受け取り、
  `x-functions-key` ヘッダで Functions を呼ぶ（Workload Identity / AAD / Bearer は不使用）。
- イメージ pull は kubelet の AcrPull(RBAC) で行うため imagePullSecret は不要。

### 7. サンプル CSV を生成してアップロード

アップロード対象の CSV は **`./csv`** 配下にまとめます（`.gitignore` 済み）。

```bash
# --- サンプル CSV を生成（./csv/valid.csv を出力） ---
python apps/storage/script-for-generating-sample-csv/generate_sample_csv.py \
  --rows 100000 --out-dir ./csv
```

アップロード方法は 2 通り。**テストはスクリプトがワンコマンドで簡単**です。

```bash
# --- (簡単) スクリプトで input/ciupload39.csv へアップロード ---
#   接続情報は Hub の terraform output から取得（サブスク ID 等の手入力は不要）。
#   規定名 input/ciupload39.csv へ同名で上書きアップロードする。Blob バージョニングが
#   有効なため過去版は版として残り、csv/upload-manifest.tsv に履歴を記録する。
bash apps/storage/script-for-generating-sample-csv/upload-csv-to-blob.sh ./csv/valid.csv
```

```bash
# --- (Storage Explorer) SAS URL を取得して貼り付け、input/ 配下へ ---
#   ファイル名は規定名 ciupload39.csv にして input/ 配下へ配置する。
terraform -chdir=terraform/envs/hub-subscription output -raw upload_container_sas_url
```

どちらの方法でもアップロードイベントで ADF パイプライン `pl_csv_ingest` が起動し、
Copy → Script (バリデーション + 入替) → Lookup → 条件付き Copy → Copy が実行されます。
（トリガー条件は **`input/` パス配下・拡張子 `.csv`・非空**。CSV はヘッダ付きで、ADF は
ヘッダ名でデータ項目へマッピングします）

### 8. 依存関係のグラフを出力

```bash
# --- Terraform のリソース依存グラフを出力（dot → png） ---
terraform -chdir=terraform/envs/hub-subscription graph | dot -Tpng > ./terraform/envs/hub-subscription/dependency_graph.png
terraform -chdir=terraform/envs/spoke-subscription graph | dot -Tpng > ./terraform/envs/spoke-subscription/dependency_graph.png
```


## 動作の流れと確認方法（ランタイム）

### エンドツーエンドの流れ

1. CSV（ヘッダ付き）を **`input/` 配下**（`ciupload39container/input/ciupload39.csv`）に配置（Storage Explorer / SAS）。
2. Storage の **`BlobCreated`** イベント → **Event Grid** → ADF トリガー `trg_csv_uploaded` が**自動起動**。
3. パイプライン `pl_csv_ingest`: Copy（CSV→`customer_info_landing`、ヘッダ名でマッピング）→ Script（バリデーション + `customer_info_production` 入替）→
   Lookup（`customer_info_error` 件数）→ 条件付き Copy（error CSV）→ Copy（success CSV を `archive/` へ）。
4. `customer_info_production` が更新される。
5. **AKS の本人特定アプリ（person-id-app）の Web UI** で name_kana/birth_ymd/cellular_phone_no を入力 →
   Function `POST /api/customers/search` を Function キーで呼び、一致する policy_no を取得・表示。

```
[Storage Explorer] --input/ciupload39.csv--> [Storage] --BlobCreated/EventGrid--> [ADF trg_csv_uploaded]
   → pl_csv_ingest (Copy→Script→Lookup→Copy) → [PostgreSQL customer_info_production]
[ブラウザ] --form--> [AKS person-id-app] --x-functions-key--> [Functions POST /api/customers/search] --> [customer_info_production]
```

### 重要な注意

- **画面は自動更新されない**。AKS アプリはページ表示時（`GET /`）に Function を呼ぶので、
  **ブラウザをリロード**すれば最新化される（サーバ push ではない）。
- CSV は **`input/` パス配下・拡張子 `.csv`・非空**でないとトリガー条件（`begins_with`/`ends_with`/
  `ignore_empty_blobs`）に一致せず**起動しない**。コンテナ直下に置くと起動しない。
- `BlobCreated` トリガーは **Event Grid** 経由。Hub サブスクリプションで **`Microsoft.EventGrid`**
  リソースプロバイダの登録が必要（未登録だとイベントが流れずトリガーされない）:
  `az provider register --namespace Microsoft.EventGrid --subscription $(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)`

### ADF ジョブの成否を確認

> サブスクリプション ID は terraform output から取得できます（手入力不要）:
> ```bash
> HUB_SUB=$(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)
> SPOKE_SUB=$(terraform -chdir=terraform/envs/spoke-subscription output -raw subscription_id)
> ```

- **ADF Studio → Monitor → Pipeline runs / Trigger runs**（`pl_csv_ingest` の Succeeded/Failed と各 Activity）。
- CLI 例:
  ```bash
  ADF=$(terraform -chdir=terraform/envs/hub-subscription output -raw data_factory_name)
  HUB_RG=$(terraform -chdir=terraform/envs/hub-subscription output -raw resource_group_name)
  HUB_SUB=$(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)
  az datafactory pipeline-run query-by-factory -g "$HUB_RG" --factory-name "$ADF" \
    --last-updated-after 2026-01-01T00:00:00Z --last-updated-before 2099-01-01T00:00:00Z \
    --subscription "$HUB_SUB" --query "value[].{pipeline:pipelineName,status:status,run:runId}" -o table
  ```
- 結果データ: `ciarchive39container/archive/success/success_*.csv`（成功行）、`archive/error/error_*.csv`（NG 行）。
- DB 直接（踏み台 MI でパスワードレス、手順4参照）:
  `psql "host=$PSQL_FQDN port=5432 dbname=appdb user=ci00-jumpbox sslmode=require" -c "SELECT count(*) FROM customer_info_production;"`
  （`customer_info_error` も同様に確認）。

### AKS アプリが Function を叩く仕組み

- 本人特定アプリ `person-id-app`: `GET /` のフォームに name_kana/birth_ymd/cellular_phone_no を入力すると
  `POST <FUNCTIONS_BASE_URL>/api/customers/search` を呼び、一致する policy_no を表示する
  （`app-for-getting-person-id/main.py`）。5xx 時は指数バックオフでリトライ。
- 認証は **Function キー方式**。`FUNCTIONS_KEY`（Secret）を `x-functions-key` ヘッダに付与して呼ぶ
  （Workload Identity / Easy Auth は不使用）。

### 失敗ケース（バリデーション NG）の確認

> **手動テストの実施手順**（CSV 投入 / API リクエストの 2 経路・網羅パターン表つき）は
> [test/README.md](test/README.md) を参照。過去の実測結果とナレッジは [docs/test.md](docs/test.md)。

フォーマット違反 CSV を投入して、NG 行が `customer_info_error` / `archive/error/` へ振り分けられることを確認できます。
`customer_info_landing` は **`VARCHAR(255)`**（寛大上限・NULL 可）なので、**桁数超過値もロードに成功**し
（旧構成のような `22001 value too long` のハード Fail はしない）、検証 SQL の必須/桁数/型/id重複チェックで
`customer_info_error` に振り分けられます。**いずれの違反種別でも pipeline は Succeeded** になります。

> **エラー行があっても Succeeded**: バリデーションエラーがあっても `pl_csv_ingest` は Succeeded になり、
> Failed Activity は出ません。NG 行は `customer_info_error` テーブルと `ArchiveError` が出力する
> `archive/error/*.csv` で確認します（以前あった意図失敗による `ActivityFailedRuns` 検知シグナルは廃止しました）。

```bash
# --- 違反テスト CSV を種別ごとに生成（./csv 配下、意図がファイル名で分かる）---
python apps/storage/script-for-generating-sample-csv/generate_invalid_csv.py \
  --valid 5 --per-category 2 --out-dir ./csv
```

生成されるファイルと期待結果（いずれも `--valid 5 --per-category 2`。すべて Succeeded）:

| ファイル（意図が名前で分かる） | 期待結果（`customer_info_error` の件数と理由） |
| --- | --- |
| `invalid_id_empty.csv` | error=2（`policy_no required`）/ production=5 |
| `invalid_name_hiragana.csv` | error=2（`name_kana must be zenkaku katakana`）/ production=5 |
| `invalid_birthdate_7digit.csv` | error=2（`birth_ymd must be 8 digits`）/ production=5 |
| `invalid_phone_nodash.csv` | error=2（`cellular_phone_no must be XXX-XXXX-XXXX`）/ production=5 |
| `invalid_id_overlength.csv` | error=2（`policy_no too long (max 10)`）/ production=5 |
| `invalid_name_overlength.csv` | error=2（`name_kana too long (max 50)`）/ production=5 |
| `invalid_id_duplicate.csv` | error=**4**（`policy_no duplicated`：重複 policy_no は全行NG）/ production=5 |
| `invalid_mixed.csv` | error=**16**（6種×2 + 重複2組×2行）/ production=5 |

アップロードは手順 7 と同じスクリプトを使います（規定名 `input/ciupload39.csv` へ同名上書き）:

```bash
# 例: 4 種混在ファイルを投入 → 自動でパイプライン起動
bash apps/storage/script-for-generating-sample-csv/upload-csv-to-blob.sh ./csv/invalid_mixed.csv
```

実行時は `ArchiveError` が毎回走り、NG 行は
`ciarchive39container/archive/error/error_*.csv` に出力されます（エラーが無い回はヘッダのみの空 CSV）。

確認コマンド例（4 アクティビティの成否一覧。error 件数は `customer_info_error` テーブルか上記 CSV で確認）:

```bash
ADF=$(terraform -chdir=terraform/envs/hub-subscription output -raw data_factory_name)
HUB_RG=$(terraform -chdir=terraform/envs/hub-subscription output -raw resource_group_name)
HUB_SUB=$(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)
RID=$(az datafactory pipeline-run query-by-factory -g "$HUB_RG" --factory-name "$ADF" \
  --subscription "$HUB_SUB" --last-updated-after 2026-01-01T00:00:00Z --last-updated-before 2099-01-01T00:00:00Z \
  --query "sort_by(value,&runStart)[-1].runId" -o tsv)
az datafactory activity-run query-by-pipeline-run -g "$HUB_RG" --factory-name "$ADF" --subscription "$HUB_SUB" \
  --run-id "$RID" --last-updated-after 2026-01-01T00:00:00Z --last-updated-before 2099-01-01T00:00:00Z \
  --query "value[].{activity:activityName,status:status}" -o table
```

> **NULL の扱い**: CSV の空フィールドは Copy で **NULL** としてロードされる。検証 SQL は
> `COALESCE(<regex>, false)` で NULL セーフにしてあり、正常側 INSERT とエラー側 INSERT を厳密な補集合に
> している（これを怠ると `NOT(NULL AND …) = NULL` で空欄行が**両方から漏れて黙って消える**）。詳細は
> [docs/troubleshooting.md](./docs/troubleshooting.md) §13。

## コスト節約（一時停止 / 再開）

作業を中断する間は、リソースを**削除せず停止/割り当て解除**するだけで idle のノード・VM 課金を抑えられます
（再開も 1 コマンド、Terraform state には影響しません）。

```bash
# --- 変数（サブスク ID も output から取得） ---
HUB_SUB=$(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)
SPOKE_SUB=$(terraform -chdir=terraform/envs/spoke-subscription output -raw subscription_id)
HUB_RG=$(terraform -chdir=terraform/envs/hub-subscription output -raw resource_group_name)
SPOKE_RG=$(terraform -chdir=terraform/envs/spoke-subscription output -raw resource_group_name)
AKS=$(terraform -chdir=terraform/envs/spoke-subscription output -raw aks_cluster_name)
PG=$(terraform -chdir=terraform/envs/spoke-subscription output -raw psql_server_name)
JUMPBOX=$(terraform -chdir=terraform/envs/hub-subscription output -raw jumpbox_name)
```

```bash
# --- 停止（中断時） ---
az aks stop -g "$SPOKE_RG" -n "$AKS" --subscription "$SPOKE_SUB"                      # AKS ノード課金停止
az postgres flexible-server stop -g "$SPOKE_RG" -n "$PG" --subscription "$SPOKE_SUB"   # PG 停止（最大7日・自動再起動）
az vm deallocate -g "$HUB_RG" -n "$JUMPBOX" --subscription "$HUB_SUB"                  # 踏み台 VM 割り当て解除
```

```bash
# --- 再開（作業再開時） ---
az aks start -g "$SPOKE_RG" -n "$AKS" --subscription "$SPOKE_SUB"
az postgres flexible-server start -g "$SPOKE_RG" -n "$PG" --subscription "$SPOKE_SUB"
az vm start -g "$HUB_RG" -n "$JUMPBOX" --subscription "$HUB_SUB"
```

- **停止できない常時課金**: Functions EP1（〜$0.20/h）は停止不可＝削除しかない。
  踏み台 VM は `az vm deallocate` で停止すれば課金を抑えられる（public IP の Static 分はごく小額残る）。
  短時間の中断なら放置が無難。完全にゼロにするなら `terraform destroy`（再構築コスト大）。
- 注意: 上記は Terraform 管理外の電源操作なので **state は壊れない**。PG 停止は接続が切れ、7 日経過で自動再起動。
  AKS の LoadBalancer 用 Public IP などごく小額は残る。

## CSV ファイル仕様

- アップロード先: `ci00storageaccount` / コンテナ `ciupload39container` / パス `input/`
- File Name: `ciupload39.csv`（毎回同名。Blob バージョニングで過去版を保持）
- Encoding: Shift_JIS / 改行 LF / フッタなし / `,` 区切り
- Header（**有り**）: `顧客_番号, 顧客_氏名, 顧客_生年月日, 顧客_電話番号`
- データ件数: 10 万件想定
- ヘッダ → データ項目 のマッピング（ADF はヘッダ名でマッピング）:
  - `顧客_番号` → `policy_no`（string, max 10）
  - `顧客_氏名` → `name_kana`（string, max 50, 全角カタカナ）
  - `顧客_生年月日` → `birth_ymd`（string, max 8, YYYYMMDD）
  - `顧客_電話番号` → `cellular_phone_no`（string, max 15, XXX-XXXX-XXXX）

## セキュリティ方針

- **Storage Account**: public access は IP allowlist + SAS のみ。ADF からは Managed Private Endpoint。
- **PostgreSQL (Flexible Server)**: `public_network_access_enabled = false`、Private Endpoint のみ。Entra ID 認証を有効化し、ADF / Function はマネージドID で接続（最小権限の AAD ロール）。
- **ADF**: Managed VNet + Managed Private Endpoint。SystemAssigned マネージドID。PostgreSQL へは AAD/MSI 認証（`azapi_resource` で V2 リンクサービスを作成）。
- **Functions**: Elastic Premium (EP1) + VNet 統合 (outbound) / Private Endpoint (inbound)。public access 無効。
- **AKS → Functions の閉域 + 認証**（2層）:
  - 網レベル: AKS と func PE は同一 Spoke VNet。`snet-pe-func` の NSG で `snet-aks` からの 443 のみ許可し、他 VNet 送信元（Hub 踏み台等）は deny（`nsg.tf`、PE に NSG を効かせるため `private_endpoint_network_policies = "Enabled"`）。
  - 認証レベル: **Function キー方式**。Python v2 モデルの route `auth_level=FUNCTION` で Functions ホストが `x-functions-key` を検証する。AKS は Terraform 出力 `function_default_key` を Secret 経由で Pod に渡す。Easy Auth (AAD) / Workload Identity は不使用。
    （Function → PostgreSQL の接続は引き続き Function の SystemAssigned マネージドID + AAD 認証）。
- **踏み台 VM**: public IP + SSH。接続元は NSG で `allowed_upload_ip` のみ許可 (22/TCP)。

詳細は [`docs/auth.md`](./docs/auth.md)（認証・権限）、[`docs/network.md`](./docs/network.md)（ネットワーク制御・閉域化）、[`docs/pipeline.md`](./docs/pipeline.md)（ADF 取り込みパイプライン）、[`docs/troubleshooting.md`](./docs/troubleshooting.md)（デプロイ時のハマりどころ）を参照。

## 既知の制約 / 検証用簡略化

- PostgreSQL への接続 (ADF / Functions) は **Entra ID + マネージドID 認証**で実装済み。
  SQL 認証 (`psqladmin`) は DB/テーブル bootstrap・break-glass 用に併存。
- **PostgreSQL は Flexible Server を採用**（Single Server は AAD 連携が扱いにくく旧世代のため）。
  ネットワークは Private Endpoint 方式（VNet 注入は不使用）にして ADF Managed PE の到達性を維持。
- **ADF→PostgreSQL の AAD 認証**は `azapi_resource`（`Microsoft.DataFactory/factories/linkedservices`）で
  Azure Database for PostgreSQL コネクタ V2 を直接記述（`authenticationType = SystemAssignedManagedIdentity`）。
  azurerm の `linked_custom_service` は `type_properties_json` を payload に載せ損ねるバグ
  ([azurerm #29379](https://github.com/hashicorp/terraform-provider-azurerm/issues/29379)) があり、
  azapi で MS 公式 JSON をそのまま投入して回避している。事前に PG 側へ `ci00-adf` の AAD ロールが必要。
- AKS → Functions の呼び出しは **Function キー方式**（`x-functions-key`）。Easy Auth / AAD アプリ /
  Workload Identity は使用しないため、AAD アプリ登録権限は不要。Function キーは共有シークレットのため
  Secret 管理が前提（Function → PostgreSQL は引き続きマネージドID + AAD）。
- AKS は private cluster ではない (kubeconfig をパブリック API から取得するため)。

## トラブルシューティング / ナレッジ

apply 時に実際に踏んだハマりどころと対処は **[`docs/troubleshooting.md`](./docs/troubleshooting.md)** に集約しています。主なもの:

- **ADF→PostgreSQL の AAD 認証で `typeProperties: {}` が空になり 400**（azurerm のバグ [#29379](https://github.com/hashicorp/terraform-provider-azurerm/issues/29379)）→ `azapi` で V2 リンクサービスを直接作成して回避
- **Functions EP1 のクォータ 0** → `EP1 VMs` と `Total Regional VMs` を増加申請
- **AKS / VM サイズがサブスク不可**（`Standard_DS2_v2` 等）→ 許可リスト内のサイズへ（tfvars の上書きに注意）
- **Storage の `ip_rules` に `/32` 不可** → 単一 IP は裸で指定
- **AAD identifier URI のテナントポリシー** → `api://<tenant-id>/<名前>` + アクセストークン v2
- **azurerm 3→4 の破壊的変更** → `enable_auto_scaling`→`auto_scaling_enabled`、`storage_account_name`→`storage_account_id`
- 踏み台 VM はパスワード認証を許可。本番では SSH 鍵 + AAD ログインを推奨。
