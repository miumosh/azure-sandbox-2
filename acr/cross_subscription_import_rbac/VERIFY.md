# 検証手順 — ACR クロスサブスクリプション import の RBAC 制御

[research.md](research.md) の机上調査を実機で確かめるための手順。
主眼は **「ソース側（サブスク A）の RBAC で import を許可 / 拒否できるか」**。

## 前提

| 項目 | 値 |
| --- | --- |
| サブスク A（ソース） | `<SUB_A_ID>` |
| サブスク B（取り込み先） | `<SUB_B_ID>` |
| ソース ACR | `acrimprbacsrc1ext0m`（RG: `acr-import-rbac-a-rg`） |
| 取り込み先 ACR | `acrimprbacdst1ext0m`（RG: `acr-import-rbac-b-rg`） |
| オペレータ | `test-user-01@<tenant>.onmicrosoft.com`（object ID `<OPERATOR_OBJECT_ID>`） |
| オペレータの前提権限 | **サブスク B の Owner**（想定する前提条件）。サブスク A には初期状態で何も持たない |
| ACR 構成 | 両方 Premium / public 無効 / trusted services ON / export policy enabled / RBAC-only モード |
| 初期データ | ソースに `hello-world:latest` |

リソースは [`terraform/`](terraform/) で構築済み。ソース側のロール付与は `assign_src_importer` で切り替える。

> 取り込み先側の Data Importer（`assign_dst_importer`）は Owner と重複するため結果に影響しない。

---

## 0. 準備

### 0.1 シェル変数

管理者（miumosh）用とオペレータ（test-user-01）用で `az` の設定ディレクトリを分ける。以降のコマンドは同じシェルで実行する。

```bash
SUB_A="<SUB_A_ID>"
SUB_B="<SUB_B_ID>"
SRC=acrimprbacsrc1ext0m
DST=acrimprbacdst1ext0m
SRC_ID=/subscriptions/$SUB_A/resourceGroups/acr-import-rbac-a-rg/providers/Microsoft.ContainerRegistry/registries/$SRC
DST_ID=/subscriptions/$SUB_B/resourceGroups/acr-import-rbac-b-rg/providers/Microsoft.ContainerRegistry/registries/$DST
OP_ID="<OPERATOR_OBJECT_ID>"
TF_DIR=~/ghq/github.com/miumosh/azure-sandbox-2/acr/cross_subscription_import_rbac/terraform

# オペレータとして az を実行するラッパー
azop() { AZURE_CONFIG_DIR=~/.azure-test-user-01 az "$@"; }
```

### 0.2 オペレータでログイン

```bash
azop login --tenant <TENANT_ID> --use-device-code
azop account list -o table   # B のみ見える（A はロール付与状況次第で見える）
```

### 0.3 オペレータの import コマンド

各ステップでタグ名だけ変えて使う（既存タグとの衝突を避けるため `--image` を毎回変える）。

```bash
op_import() {  # $1 = ソースの repo:tag, $2 = 取り込み先の repo:tag
  azop acr import --name $DST --subscription $SUB_B \
    --registry $SRC_ID --source "$1" --image "$2"
}
```

> **ロール変更の反映待ち**: ロール割り当ての追加・削除後は **5 分程度** 待ってから試す（ARM のキャッシュ）。すぐに結果が変わらない場合は数分おいて再試行し、反映までの時間も記録する。

### 0.4 結果の確認方法

両 ACR とも public 無効なので、手元から `az acr repository show-tags` 等（データプレーン）は 403 になる。結果は次で確認する。

- `az acr import` 自体の終了コード / エラーメッセージ
- 取り込み先のアクティビティログ（ARM なので見える）

```bash
az monitor activity-log list --resource-id $DST_ID --offset 1h \
  --query "[?operationName.value=='Microsoft.ContainerRegistry/registries/importImage/action'].{who:caller,status:status.value,sub:subStatus.value,time:eventTimestamp}" -o table
```

---

## 1. ソースに Data Importer あり → 成功するか

**状態**: `assign_src_importer = true`（初期状態のまま）

```bash
op_import hello-world:latest step1/hello-world:latest
```

| 期待 | 成功（両 ACR が public 無効でも trusted services で通る） |
| --- | --- |

---

## 2. ソースのロールを外す → 失敗するか

**状態変更（管理者）**:

```bash
cd $TF_DIR && terraform apply -var assign_src_importer=false
```

5 分程度待ってから:

```bash
op_import hello-world:latest step2/hello-world:latest
```

| 期待 | 失敗（B の Owner だけではソースを読めない）。**エラーメッセージ全文を記録** |
| --- | --- |

---

## 3. ソース側の最小権限（カスタムロール）

Data Importer はソース側に不要な `importImage/action` を含む。どこまで削れるかを見る。

### 3.1 カスタムロールを作成（管理者）

```bash
cat > /tmp/role-src-reader.json <<EOF
{
  "Name": "ACR Import Source Reader (test)",
  "Description": "ACR import のソース側最小権限の検証用",
  "Actions": [
    "Microsoft.ContainerRegistry/registries/read",
    "Microsoft.ContainerRegistry/registries/pull/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "AssignableScopes": ["/subscriptions/$SUB_A"]
}
EOF
az role definition create --role-definition /tmp/role-src-reader.json

cat > /tmp/role-src-readonly.json <<EOF
{
  "Name": "ACR Import Source Read Only (test)",
  "Description": "ACR import のソース側最小権限の検証用 (pull なし)",
  "Actions": ["Microsoft.ContainerRegistry/registries/read"],
  "NotActions": [],
  "DataActions": [],
  "AssignableScopes": ["/subscriptions/$SUB_A"]
}
EOF
az role definition create --role-definition /tmp/role-src-readonly.json
```

ステップ 2 の状態（Data Importer なし）から始める。

### 3.2 `registries/read` + `pull/read`

```bash
az role assignment create --assignee-object-id $OP_ID --assignee-principal-type User \
  --role "ACR Import Source Reader (test)" --scope $SRC_ID
# 5 分程度待つ
op_import hello-world:latest step3-2/hello-world:latest
```

| 期待 | 成功（要検証） |
| --- | --- |

### 3.3 `registries/read` のみ

```bash
az role assignment delete --assignee $OP_ID --role "ACR Import Source Reader (test)" --scope $SRC_ID
az role assignment create --assignee-object-id $OP_ID --assignee-principal-type User \
  --role "ACR Import Source Read Only (test)" --scope $SRC_ID
# 5 分程度待つ
op_import hello-world:latest step3-3/hello-world:latest
```

| 期待 | 失敗（pull 権限がない）。成功した場合はソースの読み取り権限チェックが `registries/read` だけで行われていることになる |
| --- | --- |

### 3.4 後片付け

```bash
az role assignment delete --assignee $OP_ID --role "ACR Import Source Read Only (test)" --scope $SRC_ID
```

（カスタムロール定義はステップ 4 の比較で使うため、最後に削除する）

---

## 4. ソースを ABAC モードにしてリポジトリ単位で制御

### 4.1 準備（管理者）

許可・拒否を比べるため、ソースに 2 つ目のリポジトリを入れてから ABAC モードに切り替える。

```bash
az acr import --name $SRC --subscription $SUB_A \
  --source mcr.microsoft.com/hello-world:latest --image denied/hello-world:latest

az acr update --name $SRC --subscription $SUB_A --role-assignment-mode rbac-abac
az acr show --name $SRC --subscription $SUB_A --query roleAssignmentMode -o tsv  # AbacRepositoryPermissions
```

> `--role-assignment-mode` が無いと言われたら `az upgrade` で CLI を更新する。

### 4.2 ABAC モード + カスタムロール（`pull/read`）→ 失敗するか

ABAC モードでは `pull/read`（AcrPull 系）が無視されるはず。

```bash
az role assignment create --assignee-object-id $OP_ID --assignee-principal-type User \
  --role "ACR Import Source Reader (test)" --scope $SRC_ID
# 5 分程度待つ
op_import hello-world:latest step4-2/hello-world:latest
az role assignment delete --assignee $OP_ID --role "ACR Import Source Reader (test)" --scope $SRC_ID
```

| 期待 | 失敗（ABAC モードでは `pull/read` が効かない） |
| --- | --- |

### 4.3 ABAC モード + Data Importer → 成功するか

```bash
cd $TF_DIR && terraform apply -var assign_src_importer=true
# 5 分程度待つ
op_import hello-world:latest step4-3/hello-world:latest
op_import denied/hello-world:latest step4-3/denied:latest
```

| 期待 | 両方成功（Data Importer は両モード対応 / レジストリ全体） |
| --- | --- |

### 4.4 ABAC モード + Repository Reader（リポジトリ条件付き）

`hello-world` リポジトリだけ読めるように条件を付ける。

```bash
cd $TF_DIR && terraform apply -var assign_src_importer=false

az role assignment create --assignee-object-id $OP_ID --assignee-principal-type User \
  --role "Container Registry Repository Reader" --scope $SRC_ID \
  --condition-version "2.0" \
  --condition "((!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/read'}) AND !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/read'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase 'hello-world'))"
# 5 分程度待つ
op_import hello-world:latest step4-4/hello-world:latest
op_import denied/hello-world:latest step4-4/denied:latest
```

| 期待 | `hello-world` は成功、`denied/hello-world` は失敗（要検証）。<br>Repository Reader は ARM の `actions` を持たないため、**両方とも失敗する可能性もある**。その場合は 4.5 へ |
| --- | --- |

### 4.5（4.4 が両方失敗した場合）ARM の `registries/read` を足す

```bash
az role assignment create --assignee-object-id $OP_ID --assignee-principal-type User \
  --role "ACR Import Source Read Only (test)" --scope $SRC_ID
# 5 分程度待つ
op_import hello-world:latest step4-5/hello-world:latest
op_import denied/hello-world:latest step4-5/denied:latest
```

### 4.6 後片付け

```bash
az role assignment delete --assignee $OP_ID --role "Container Registry Repository Reader" --scope $SRC_ID
az role assignment delete --assignee $OP_ID --role "ACR Import Source Read Only (test)" --scope $SRC_ID
az acr update --name $SRC --subscription $SUB_A --role-assignment-mode rbac
cd $TF_DIR && terraform apply   # Data Importer を戻す
```

---

## 5. ソースの export policy を無効化 → 失敗するか

Data Importer があっても、ソース側で持ち出しを全面禁止できるかを見る。

```bash
az resource update -g acr-import-rbac-a-rg -n $SRC --subscription $SUB_A \
  --resource-type Microsoft.ContainerRegistry/registries --api-version 2021-06-01-preview \
  --set properties.policies.exportPolicy.status=disabled

op_import hello-world:latest step5/hello-world:latest
```

| 期待 | 失敗。**エラーメッセージを記録**（ステップ 2 の RBAC 拒否と区別できるか） |
| --- | --- |

戻す:

```bash
az resource update -g acr-import-rbac-a-rg -n $SRC --subscription $SUB_A \
  --resource-type Microsoft.ContainerRegistry/registries --api-version 2021-06-01-preview \
  --set properties.policies.exportPolicy.status=enabled
```

---

## 6. ソース A 側に何が記録されるか

ステップ 1〜5 の後、ソース側のアクティビティログを確認する。

```bash
az monitor activity-log list --resource-id $SRC_ID --offset 6h \
  --query "[].{op:operationName.value,who:caller,status:status.value,time:eventTimestamp}" -o table
```

確認したいこと:

- オペレータ（test-user-01）の名前で、ソースに対する何らかの操作が残るか
- 残らない場合、A の管理者は「誰に読まれたか」を A 側だけでは追えない（B のアクティビティログで `importImage` の `--registry` を見るしかない）

> データプレーンのログ（`ContainerRegistryRepositoryEvents`）まで見たい場合は、ステップ 1 の前にソース ACR の診断設定で Log Analytics へ送るように設定しておく。

---

## 7.（任意）条件付きアクセスで接続元 IP を制限

Entra ID P1 が必要。ポリシーを作る場合:

- 対象ユーザ: test-user-01
- 対象アプリ: **Windows Azure Service Management API**
- 条件: ネームドロケーション（許可する IP）以外
- アクセス制御: ブロック

確認すること:

- 許可外の IP から `azop login` がブロックされるか
- 許可 IP でログイン済みのトークンを使い、別の IP から `op_import` した場合に通るか（CAE の効き方）

---

## 結果記録

| # | 状態 | 期待 | 結果 | エラー / 備考 |
| --- | --- | --- | --- | --- |
| 1 | ソースに Data Importer | 成功 | | |
| 2 | ソースのロールなし | 失敗 | | |
| 3.2 | カスタム `read` + `pull/read` | 成功？ | | |
| 3.3 | カスタム `read` のみ | 失敗？ | | |
| 4.2 | ABAC + カスタム `pull/read` | 失敗 | | |
| 4.3 | ABAC + Data Importer | 両方成功 | | |
| 4.4 | ABAC + Repository Reader（条件付き） | 許可リポジトリのみ成功？ | | |
| 4.5 | 4.4 + `registries/read` | 許可リポジトリのみ成功？ | | |
| 5 | export policy disabled | 失敗 | | |
| 6 | ソース側ログ | — | | |
| 7 | 条件付きアクセス | ブロック | | |

---

## 後片付け

```bash
az role definition delete --name "ACR Import Source Reader (test)" --scope /subscriptions/$SUB_A
az role definition delete --name "ACR Import Source Read Only (test)" --scope /subscriptions/$SUB_A
cd $TF_DIR && terraform destroy
rm -rf ~/.azure-test-user-01
```
