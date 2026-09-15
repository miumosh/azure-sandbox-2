# image_import — `az acr import` 方式（軽量・推奨）

サブスク A の private ACR から、サブスク B の private ACR へ **`az acr import`** でイメージをコピーする。
**同一 Microsoft Entra テナント**であれば、両 ACR が `public_network_access_enabled = false`（完全プライベート）でも、
**`allow trusted services`（= `network_rule_bypass_option = "AzureServices"`）**を有効にするだけで動作する。
**VNet / Private Endpoint / ピアリング / VM は一切不要。**

```
 Subscription A (from)                Subscription B (to)
┌──────────────────────┐            ┌──────────────────────────┐
│ ソース ACR           │            │ import 先 ACR            │
│ Premium / public 無効 │            │ Premium / public 無効     │
│ trusted services ON  │            │ trusted services ON      │
└──────────┬───────────┘            └────────────┬─────────────┘
           │  ACR import (信頼サービス) が                       │
           │  Azure バックボーン経由でソースを読み取り、         │
           └──────────────  先 ACR へ書き込む  ────────────────┘
                         ▲
            import 実行 ID (UAMI 等) が
            source/target 双方に
            "Container Registry Data Importer and Data Reader"
```

## なぜ private 同士でも動くのか

- `az acr import` は **ARM（コントロールプレーン）操作**。実体のコピーは **ACR 自身（＝信頼サービス）** が Azure 内部で行う。
- ソース ACR の `allow trusted services` が ON なら、ACR import はソースのネットワーク制限を**バイパス**して読み取れる（顧客の Private Endpoint は経由しない）。
- public 無効ソースは **resource ID で指定**（`--registry <A の resource ID>`、`--source` は `repo:tag` のみ）。

> 公式: ACR import は trusted services の一つ。詳細は本ディレクトリ親の [README](../README.md) のリンク参照。

## テナントを跨ぐと可否はどうなるか（なぜそうなるのか）

import の可否は **テナント境界 × ソースの public 公開状態** で決まる。

| ソース A の状態 | 同一 Entra テナント | 別テナント（クロステナント） |
|---|---|---|
| public 有効 | ◎ import 可 | ◎ import 可（public 経由で読める） |
| **public 無効（private）** | ◎ import 可（trusted services + resource ID 指定） | ✕ **import 非対応** |

### なぜ「同一テナント × public 無効」は動くのか
- import の実体コピーは **ACR（信頼サービス）** が Azure バックボーン内で行う。`allow trusted services` が ON なら、
  ACR はソースのネットワーク制限を**バイパス**して読み取れる。ネットワーク到達性は問題にならない。
- 認証は **同一テナント内の Entra トークン**で完結する。実行 ID に source/target 双方のロールがあれば権限も満たせる。
- → ネットワークと認証の両軸が満たせるので動く。

### なぜ「別テナント × public 無効」は動かないのか
- trusted services によるバイパスは **同一テナント内**を前提とした仕組み。**テナント境界を越えると、信頼サービス経由での
  プライベートアクセスが成立しない**（公式に *"Cross-tenant import isn't supported over public access disabled registry."* と明記）。
- 別テナントのソースを読むにはソースが **public で到達可能**である必要がある。public 無効だと到達経路自体が無く、import は失敗する。
- → 認証はクロステナントでも組めるが、**ネットワーク到達性（バイパス）がテナント境界で切れる**ため不可。
  このケースは [`image_pull_push`](../image_pull_push/README.md)（Runner で pull/push）を使う。

## ネットワークの結合（VNet Peering 等）は不要

**この import 方式では、VNet / Subnet / Private Endpoint / Private DNS / VNet Peering / Runner VM は一切不要。**

| ネットワーク要素 | import 方式での要否 | 理由 |
|---|---|---|
| VNet / Subnet | **不要** | import は ARM（コントロールプレーン）操作。顧客ネットワークを通らない |
| Private Endpoint | **不要** | コピーは ACR が Azure バックボーン経由で実行。顧客 PE を経由しない |
| Private DNS | **不要** | データ面エンドポイントへ顧客側から名前解決する経路を使わない |
| **VNet Peering** | **不要** | A/B 間のネットワーク結合は import に関与しない。テナント/サブスクが別でも Azure 内部で完結 |
| Runner VM / コンピュート | **不要** | 実体コピーは ACR が行う。実行は ARM 呼び出しのみ（Cloud Shell / CI で可） |

> VNet Peering を含むネットワーク結合が必要になるのは、import ではなく **Runner で docker pull/push する
> [`image_pull_push`](../image_pull_push/README.md) 方式**、または **実行時に B のワークロード（AKS 等）が private pull する経路**を
> 別途用意する場合のみ。import そのものには不要。

## 前提・制約

- **同一 Entra テナント必須。** クロステナント × public 無効は import 非対応 → その場合は [`image_pull_push`](../image_pull_push/README.md) を使う。
- 両 ACR とも **Premium**・`allow trusted services` 有効（本コードで設定済み）。
- import 実行 ID は source/target 双方に **`Container Registry Data Importer and Data Reader`** ロールが必要（本コードで付与）。

## デプロイ順序・連携情報・必須設定（要点）

### 1. どちらを先にデプロイするか → **`to`(B) → `from`(A)** の順

A 側の role assignment が B 側 UAMI の `principal_id` を必要とする（A→B の循環依存）。
これを一方向に解くため、**先に B(`to`) を apply** して UAMI を作り、その `principal_id` を A(`from`) に渡す。
`from`(A) の `source_acr_id` 等は B のリソース作成には不要（import コマンド output の組み立て専用）なので、
**任意で最後に `to`(B) を再 apply** すると `az_acr_import_cmd` output が完成形になる。

```
to(B) apply ──(runner principal_id)──▶ from(A) apply ──(source_acr_id/login_server)──▶ to(B) 再apply(任意)
```

### 2. 何の情報を連携するか

| # | 方向 | 値 | 取得元（output） | 渡す先（variable / 用途） | 必須 |
|---|------|----|------------------|--------------------------|------|
| 1 | B → A | UAMI の principal_id | `to`: `runner_identity_principal_id` | `from`: `import_runner_principal_id`（A 側ロール付与） | ✅ 必須 |
| 2 | A → B | ソース ACR の Resource ID | `from`: `source_acr_id` | `to`: `source_acr_id`（import の `--registry`） | △ output 用 |
| 3 | A → B | ソース ACR の login server | `from`: `source_acr_login_server` | `to`: `source_acr_login_server`（参考表示） | △ output 用 |
| 4 | 実行時 | UAMI の client_id | `to`: `runner_identity_client_id` | `az login --identity --username <client_id>` | 実行 ID に UAMI を使う場合 |

> #1 だけがリソース作成に必須。#2/#3 は import コマンド文字列を output に出すためだけの値で、未設定でも import 自体は動く（手動で `--registry` に Resource ID を渡せばよい）。

### 3. どの設定を入れるべきか（両 ACR 共通・本コードで設定済み）

| 設定 | 値 | 理由 |
|------|----|------|
| `sku` | `Premium` | import / trusted services は Premium 必須 |
| `public_network_access_enabled` | `false` | 完全プライベート要件 |
| `network_rule_bypass_option` | `"AzureServices"` | **import 成立の必須条件**（allow trusted services）。OFF だと import 失敗 |
| `admin_enabled` | `false` | basic 認証を無効化（RBAC のみ） |
| RBAC | import 実行 ID に source/target **双方** へ `Container Registry Data Importer and Data Reader` | A 読み取り + B 書き込みの両権限 |
| テナント | source/target が **同一 Entra テナント** | クロステナント×public 無効は import 非対応 |

## 構成

| 対象 | 設定 | ファイル |
|------|------|----------|
| A: ソース ACR | Premium / public 無効 / trusted services | `from/acr.tf` |
| A: RBAC | import 実行 ID に Data Importer&Reader（source） | `from/role.tf` |
| B: import 先 ACR | Premium / public 無効 / trusted services | `to/acr.tf` |
| B: Identity | import 実行用 UAMI | `to/identity.tf` |
| B: RBAC | UAMI に Data Importer&Reader（target） | `to/role.tf` |
| 実行 | `az acr import` | 下記手順 |

## 適用手順

A の RBAC は B の UAMI principal_id に依存するため、**B(`to`) → A(`from`) の順**で apply。

```bash
# 1) B 側 (import 先 + 実行用 UAMI)
cd to
cp terraform.tfvars.example terraform.tfvars   # 値を編集
terraform init && terraform apply
terraform output -raw runner_identity_principal_id   # A へ渡す

# 2) A 側 (ソース)。import_runner_principal_id に上の値を設定
cd ../from
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
terraform output                                # source_acr_id / login_server を取得

# 3) (任意) to/terraform.tfvars の source_acr_* を埋めて再 apply すると
#    `az_acr_import_cmd` output が完成形になる
```

## import 実行

import は ARM 操作なので**コンピュートは不要**。下記いずれかの ID で実行する（source/target にロールがあること）：
- B の UAMI を割り当てた CI / VM / Cloud Shell で `az login --identity --username <client_id>`
- もしくは Owner 等の権限を持つユーザー / CI のサービスプリンシパル

```bash
# ソース A は public 無効のため --registry に resource ID、--source は repo:tag のみ
az acr import \
  --name <target_acr_name> \
  --source <repo:tag> \
  --image <repo:tag> \
  --registry <source_acr_id>     # = from output: source_acr_id
```

`to` の output `az_acr_import_cmd` にこの形のコマンドが生成される（`source_acr_*` 設定時）。

## 動作確認（手動）

### 事前: ソース A にイメージを投入
A 自身も import で公開レジストリから取得できる（A が public 無効でも、import は制御プレーン操作なので可）:
```bash
az acr import --name <source_acr_name> --subscription <A_SUB> \
  --source mcr.microsoft.com/hello-world:latest --image hello-world:latest
```

### A → B へ import 実行
```bash
az acr import --name <target_acr_name> --subscription <B_SUB> \
  --source hello-world:latest --image hello-world:latest \
  --registry <source_acr_id>          # from output: source_acr_id
# 成功すれば exit 0（同期操作。失敗時はエラーを返す）
```

### なぜ `az acr repository list` は 403 になるのか（重要）
```text
$ az acr repository list -n acrimportsourceacrxxx
Unable to get AAD authorization tokens ... CONNECTIVITY_REFRESH_TOKEN_ERROR
Access to registry '...azurecr.io' was denied. Response code: 403 ...
Admin user is disabled.  Username:
```
`repository list` / `show-tags` は **データプレーン**操作で、成立には **2 軸**が必要：

1. **ネットワーク到達性**: private(public 無効) ACR のデータ面エンドポイントに届くこと
   → VNet 内 + Private Endpoint 経由、もしくは public を一時有効化していること。
2. **データプレーン RBAC**: 実行 ID が **`AcrPull`**（ABAC なら `Container Registry Repository Reader`）を持つこと
   → **`Owner`/`Contributor` では不可**（これらは dataAction を含まない）。`admin user` も無効なので basic 認証も不可。

上の 403 は「public 無効で到達できない」＋「Owner にデータ面読み取り権限がない」の両方が原因。
private ACR の中身を直接見るには、下記いずれかで **2 軸を満たす**必要がある。

### 方法A（推奨・非侵襲）: 再 import の Conflict で存在確認
ネットワークも RBAC も変更せずに「イメージが入ったか」だけ確認したいとき。
`--force` なしの再 import は既存タグに対し Conflict を返す：
```bash
az acr import --name <target_acr_name> --subscription <B_SUB> \
  --source hello-world:latest --image hello-world:latest --registry <source_acr_id>
# => ERROR: (Conflict) ... Tag hello-world:latest already exists in target registry.
#    この "already exists" が出れば B に存在する証明。
```

### 方法B: VNet 内から参照（実運用に近い）
PE を持つ VNet 内の VM / Cloud Shell(VNet 統合) などで、`AcrPull` を持つ ID で：
```bash
az login --identity --username <uami_client_id>   # AcrPull 保有の UAMI を割り当てたホスト
az acr login --name <acr_login_server>            # 名前は Private DNS で私設 IP に解決
az acr repository list   --name <acr_name> -o table
az acr repository show-tags --name <acr_name> --repository hello-world -o table
```
> この import 方式では VNet/PE を作っていないため、参照用に別途用意するか、`image_pull_push` 構成を流用する。

### 方法C: 一時的に public + AcrPull を付与して確認 → 必ず復旧
手元（VNet 外）から手早く中身を見たいとき。**検証後に必ず元へ戻す**こと。
```bash
ME=$(az ad signed-in-user show --query id -o tsv)
ACR_ID=$(az acr show -n <acr_name> --subscription <SUB> --query id -o tsv)

# (1) データプレーン RBAC: 自分に AcrPull
az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
  --role AcrPull --scope "$ACR_ID"
# (2) ネットワーク到達性: public を一時有効化
az acr update -n <acr_name> --subscription <SUB> --public-network-enabled true
sleep 30   # 反映待ち

az acr repository list --name <acr_name> -o table
az acr repository show-tags --name <acr_name> --repository hello-world -o table

# (3) 復旧（private へ戻す + ロール削除）
az acr update -n <acr_name> --subscription <SUB> --public-network-enabled false
az role assignment delete --assignee "$ME" --role AcrPull --scope "$ACR_ID"
```
> 注: public 有効化は Terraform state とドリフトするため、確認後に必ず false へ戻す（または `terraform apply` で再収束）。

実機での検証記録は [`DEPLOY_VERIFY_LOG.md`](DEPLOY_VERIFY_LOG.md) を参照。

## 補足

- ロール `Container Registry Data Importer and Data Reader` が無い環境では、source 側 `AcrPull` +
  target 側に importImage 権限（Contributor 等）でも代替可。
- `allow trusted services` を OFF にすると import は失敗する（本コードは ON 固定）。
- 実行時に B のワークロード（AKS 等）が **private pull** する経路が別途必要なら、`image_pull_push` 側の
  VNet/PE/DNS パターンを参考にする。
