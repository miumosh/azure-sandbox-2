# ACR クロスサブスクリプション import を RBAC で制御する — 机上調査

調査日: 2026-10-19
前提: **同一 Entra テナント**、サブスクリプション **A** の ACR（ソース `acrsrc`）→ サブスクリプション **B** の ACR（取り込み先 `acrdst`）へ `az acr import` でイメージをコピーする。
認証は **リポジトリスコープトークン / admin user / SP シークレットを使わず、Entra ID のユーザ（またはグループ）＋ Azure RBAC** で行う。

> 本書は公式ドキュメントと `az role definition list` で取得したロール定義に基づく**机上の整理**。「要検証」と書いた項目は実機で確かめる必要がある。

---

## 1. 結論サマリ

| 問い | 回答 |
| --- | --- |
| トークンなしで import できるか | **できる。** 同一テナントなら `--registry <ソース ACR のリソース ID>` を指定すれば、**呼び出したユーザ自身の Entra ID 権限**でソースを読める（資格情報の受け渡しは不要） |
| ユーザに付与するロール（公式推奨） | **ソース ACR と取り込み先 ACR の両方**に `Container Registry Data Importer and Data Reader` |
| ロールの付与先スコープ | **各 ACR リソース単位**（サブスクリプションや RG ではない）にすると「どの ACR から/へ」を限定できる |
| 実行コマンド | `az acr import -n acrdst --subscription <B> --registry <A の ACR リソースID> --source repo:tag --image repo:tag` |
| ネットワーク | ソース・取り込み先とも private（PE / ファイアウォール）でも、**「信頼されたサービスを許可」（既定 ON）**なら import 可能。VNet やピアリングは不要 |
| ソース IP で制御できるか | **ACR のファイアウォールでは不可**（import は ARM の制御プレーン操作のため）。**Entra 条件付きアクセス（Azure Management + ネームドロケーション）**で「どの IP から ARM 操作ができるか」を制御するのが実質的な手段 |
| 取り込み先 ACR の限定 | **可能。** ロールの割り当てスコープで制御する（B の特定 ACR にだけ付与する） |
| リポジトリ単位の限定 | **Data Importer ロールは ABAC 条件に非対応**のため、組み込みロールだけでは不可（§5.3） |

---

## 2. 仕組み（誰が何を権限チェックされるか）

```
[オペレータ (Entra ユーザ)]
   │  az login（ここで条件付きアクセス：MFA / IP / デバイス などを評価）
   │
   │  ① POST https://management.azure.com/.../registries/acrdst/importImage
   │     body: { source: { resourceId: <acrsrc の ID>, sourceImage: "repo:tag" }, targetTags: [...] }
   ▼
[Azure Resource Manager]
   │  ② RBAC チェック（呼び出しユーザに対して）
   │     - acrdst : Microsoft.ContainerRegistry/registries/importImage/action
   │     - acrsrc : ソースからの読み取り権限（公式手順では Data Importer ロールを要求）
   ▼
[ACR サービス (acrdst)]
   │  ③ ACR サービス自体が acrsrc から blob / manifest を取得
   │     （Azure バックボーン経由。trusted services で両 ACR のネットワーク制限をバイパス）
   ▼
[acrdst に manifest / tag を書き込み]
```

ポイント:

- import は **データプレーン（`*.azurecr.io`）ではなく ARM（`management.azure.com`）の POST アクション**。オペレータの端末は ACR のエンドポイントに到達できる必要がない。
- そのため **オペレータには取り込み先の push 権限（`AcrPush` / `Repository Writer`）は不要**。書き込みは `importImage/action` で許可される。
- ソースからの取得は ACR サービスが行うが、**ソースを読む権限があるかどうかは呼び出しユーザで判定**される（だから両方の ACR にロールが要る）。

---

## 3. 必要な設定（ACR ごと）

### 3.1 ソース ACR（サブスク A / `acrsrc`）

| 項目 | 設定 | 補足 |
| --- | --- | --- |
| RBAC | オペレータ（またはそのグループ）に **`Container Registry Data Importer and Data Reader`** を `acrsrc` スコープで付与 | 公式手順の記載。§5.1 の最小権限案も参照 |
| ネットワーク | public 無効 / PE / IP ルールでも可。ただし **`--allow-trusted-services true`（既定）** | Terraform: `network_rule_bypass_option = "AzureServices"` |
| export policy | **`enabled`（既定）のままにする** | `disabled` にすると**この ACR からの import が一切できなくなる**（§5.4） |
| リソースプロバイダ | サブスク A で `Microsoft.ContainerRegistry` が登録済みであること | 公式の注記：両方のリージョン/サブスクで登録が必要 |
| リージョン | ソースは**ホームリージョンのみ**が対象（geo レプリカのリージョナルエンドポイントは不可） | |

### 3.2 取り込み先 ACR（サブスク B / `acrdst`）

| 項目 | 設定 | 補足 |
| --- | --- | --- |
| RBAC | オペレータに **`Container Registry Data Importer and Data Reader`** を `acrdst` スコープで付与 | import のトリガー＋取り込み結果の確認（pull / タグ参照）ができる。**push・削除はできない** |
| ネットワーク | private でも可。**`--allow-trusted-services true`（既定）** | |
| 上書き防止（任意） | 既存タグを保護したい場合はタグロック（`az acr repository update --write-enabled false`） | `az acr import --force` は既存タグを上書きするため |

### 3.3 ロール割り当てを行う人

- それぞれの ACR に対して **`Owner` または `Role Based Access Control Administrator`（または User Access Administrator）** が必要。
- A と B でサブスクリプションの管理者が別なら、**それぞれの管理者が自分の ACR に割り当てる**ことになる（ソース側の「読ませてよいか」は A の管理者が判断できる構造になる）。

---

## 4. 付与するロールとコマンド

### 4.1 ロール定義（`az role definition list` で取得した実定義）

**Container Registry Data Importer and Data Reader**（ID: `577a9874-89fd-4f24-9dbd-b5034d0ad23a`）

```json
"actions": [
  "Microsoft.ContainerRegistry/registries/importImage/action",
  "Microsoft.ContainerRegistry/registries/read",
  "Microsoft.ContainerRegistry/registries/pull/read"
],
"dataActions": [
  "Microsoft.ContainerRegistry/registries/repositories/content/read",
  "Microsoft.ContainerRegistry/registries/repositories/metadata/read",
  "Microsoft.ContainerRegistry/registries/catalog/read"
]
```

- `pull/read`（RBAC-only モードで使われる）と `repositories/*/read`（ABAC モードで使われる）の両方を持つため、**ACR のロール割り当てモード（RBAC-only / RBAC+ABAC）どちらでも使える**。
- 一方で **ABAC 条件は非対応**（レジストリ全体のロール）。

比較用:

| ロール | actions | dataActions | 備考 |
| --- | --- | --- | --- |
| `AcrPull` | `registries/pull/read` | — | **ABAC モードの ACR では無視される** |
| `AcrPush` | `pull/read`, `push/write` | — | 同上 |
| `Container Registry Repository Reader` | — | `repositories/content/read`, `metadata/read` | ABAC 条件でリポジトリ限定可 |
| `Contributor` | `*` | — | import 可能だが過剰。ABAC モードでは data 権限は付かない |

### 4.2 ロール割り当て（Entra グループに付与する例）

ユーザ個人ではなく **セキュリティグループ**（例: `sg-acr-importer`）に付与し、メンバー管理で運用するのがおすすめ。

```bash
GROUP_ID=$(az ad group show -g sg-acr-importer --query id -o tsv)

SRC_ID=$(az acr show -n acrsrc --subscription <SUB_A> --query id -o tsv)
DST_ID=$(az acr show -n acrdst --subscription <SUB_B> --query id -o tsv)

# ソース ACR（サブスク A の管理者が実行）
az role assignment create \
  --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
  --role "Container Registry Data Importer and Data Reader" \
  --scope "$SRC_ID"

# 取り込み先 ACR（サブスク B の管理者が実行）
az role assignment create \
  --assignee-object-id "$GROUP_ID" --assignee-principal-type Group \
  --role "Container Registry Data Importer and Data Reader" \
  --scope "$DST_ID"
```

### 4.3 import コマンド（オペレータが実行）

```bash
az login            # 条件付きアクセスはここで評価される

az acr import \
  --name acrdst \
  --subscription <SUB_B> \
  --registry /subscriptions/<SUB_A>/resourceGroups/<RG_A>/providers/Microsoft.ContainerRegistry/registries/acrsrc \
  --source myapp:1.0.0 \
  --image myapp:1.0.0
```

- `--registry` は**ソース ACR のリソース ID**。これを指定すると呼び出し元の Entra 権限でソースにアクセスする。
- `--source` は **`repo:tag` のみ**（ログインサーバ名を付けない）。ダイジェスト指定 `repo@sha256:...` も可。
- `--name` は取り込み先。別サブスクなので `--subscription <SUB_B>` を付ける（または `az account set`）。
- 既存タグを上書きする場合のみ `--force`。
- `--username` / `--password` は**付けない**（付けるとトークン / SP 認証の経路になる）。
- ソースの public アクセスが有効なら `--source acrsrc.azurecr.io/myapp:1.0.0` 形式でも動くが、**リソース ID 指定に統一するほうが private 化した後も同じコマンドで済む**。

PowerShell の場合:

```powershell
Import-AzContainerRegistryImage -RegistryName acrdst -ResourceGroupName <RG_B> `
  -SourceRegistryResourceId '/subscriptions/<SUB_A>/resourceGroups/<RG_A>/providers/Microsoft.ContainerRegistry/registries/acrsrc' `
  -SourceImage myapp:1.0.0 -TargetTag myapp:1.0.0
```

### 4.4 確認

```bash
az acr repository show-tags -n acrdst --repository myapp --subscription <SUB_B> -o table
az monitor activity-log list --resource-id "$DST_ID" --offset 1h \
  --query "[?operationName.value=='Microsoft.ContainerRegistry/registries/importImage/action'].{who:caller,status:status.value,time:eventTimestamp}" -o table
```

---

## 5. Tips: どこまで制御できるか

### 5.1 最小権限化（カスタムロール案）— 要検証

公式は「両方に Data Importer」だが、このロールは
- ソース側に**不要な `importImage/action`** を含む（＝ A へも何かを import できてしまう）
- 取り込み先側に**全リポジトリの読み取り**を含む

ので、さらに絞るならカスタムロールに分ける案がある。

| 用途 | 想定 actions / dataActions | 状態 |
| --- | --- | --- |
| ソース用「Import Source Reader」 | `registries/read`, `registries/pull/read`（RBAC-only）または dataActions `repositories/content/read`, `metadata/read`（ABAC モード） | **要検証**：ARM がソース側で何をチェックしているかは公式に明記なし |
| 取り込み先用「Import Trigger」 | `registries/importImage/action`, `registries/read` | **要検証**：read 系なしでも import 自体は通るはず。結果確認はできなくなる |

> 旧ドキュメントでは「ソース側は Reader（または AcrPull）、取り込み先は Contributor か importImage を含むカスタムロール」という記載だった。現行ドキュメントは Data Importer に統一されている。

### 5.2 「特定の dest ACR にだけ」import させる

- **ロール割り当てのスコープ**で実現する。Data Importer を `acrdst` リソースにだけ付与すれば、他の ACR へは import できない。
- 逆に **サブスクリプション / RG スコープで付与すると、その配下の全 ACR が対象になる**ので避ける。
- 「A の ACR から B の ACR へだけ」という**ペアの制約**は RBAC では表現できない（ソースと取り込み先の権限は独立にチェックされる）。両方に権限を持つ ACR の組み合わせなら、どの方向でも import できる。

### 5.3 リポジトリ単位の制御

| やりたいこと | 可否 | 方法 |
| --- | --- | --- |
| 取り込み先で書き込めるリポジトリを限定 | **不可**（組み込み） | Data Importer は ABAC 条件非対応。`importImage/action` は制御プレーンの action なので ABAC 条件（`repositories:name`）も付けられない |
| ソースで読めるリポジトリを限定 | **要検証** | ソースを ABAC モード（`--role-assignment-mode rbac-abac`）にして、Data Importer ではなく **`Container Registry Repository Reader` + `repositories:name` 条件**を付与し、それで import が通るか確認する（公式には SP 認証経路でこの組み合わせが記載されている） |
| 既存タグの上書き防止 | 可 | 取り込み先でタグ / リポジトリをロック（`--write-enabled false`） |

### 5.4 ソース側で import を全面的に止める（データ持ち出し防止）

- ソース ACR の **`exportPolicy.status = disabled`** で、**この ACR から他の ACR への import とエクスポートパイプラインがブロック**される。
- 条件: Premium SKU、**public ネットワークアクセス無効**、既存のエクスポートパイプラインなし。
- **ユーザ単位の例外は作れない**（全か無か）。今回の要件とは逆向きの制御だが、「A から持ち出させたくない ACR」を明示的に守る手段として覚えておく。

```bash
az resource update -g <RG_A> -n acrsrc \
  --resource-type Microsoft.ContainerRegistry/registries --api-version 2021-06-01-preview \
  --set properties.policies.exportPolicy.status=disabled \
  --set properties.publicNetworkAccess=disabled
```

- 逆に **`--allow-trusted-services false`** にしても、ネットワーク制限がある ACR への import / からの import は止まる（こちらも ACR 単位で全か無か）。

### 5.5 ソース IP（オペレータの接続元）による制御

| 手段 | 効くか | 説明 |
| --- | --- | --- |
| ACR ファイアウォール（IP ルール）/ Private Endpoint | **効かない** | ACR ファイアウォールが制限するのはデータプレーン（`*.azurecr.io`）だけ。import は ARM 経由の制御プレーン操作で、データ取得は ACR サービスが trusted services で行う |
| **Entra 条件付きアクセス** | **効く（推奨）** | 対象アプリ「**Windows Azure Service Management API**」（= Azure CLI / PowerShell / ポータルの ARM 操作）に対し、**ネームドロケーション（社内の送信元 IP）以外からはブロック**。対象をグループ `sg-acr-importer` に絞れる。**Entra ID P1** が必要 |
| 条件付きアクセス（ワークロード ID） | SP なら効く | パイプラインで SP を使う場合は「Conditional Access for workload identities」で場所の制限が可能（**Workload ID Premium** が必要、**シングルテナント SP のみ**、**マネージド ID は対象外**） |
| Azure RBAC 条件（ABAC の環境属性） | **効かない** | ACR の ABAC 条件で使える属性は `repositories:name`（Request 属性）だけ。Storage のような IP / Private Link 系の環境属性はない |
| Resource Management Private Link | 参考 | ARM へのアクセスを Private Link 経由に限定する仕組み。管理グループ単位の設定で影響範囲が広いため、import のためだけに使うのは現実的でない |

> 条件付きアクセスの注意: 条件はトークン取得（サインイン）時に評価される。**CAE（継続的アクセス評価）**に対応したクライアントなら IP 変化で再評価されるが、それ以外では取得済みトークンの有効期間中は IP が変わっても使える。

### 5.6 時間・人による制御

- **PIM（Privileged Identity Management）**: Data Importer を**資格のある（eligible）割り当て**にして、作業時だけアクティブ化（承認・理由入力・MFA・有効期間を設定可）。**PIM for Groups** で `sg-acr-importer` のメンバーシップを JIT 化してもよい。Entra ID P2 / ID Governance が必要。
- 期限付きの割り当て: PIM を使わなくても、ARM のロール割り当てには有効期限がない → **期限が必要なら PIM が前提**。

### 5.7 監査

- 取り込み先 B の **アクティビティログ**に `Microsoft.ContainerRegistry/registries/importImage/action` が呼び出し元 UPN 付きで残る（§4.4）。
- ソース A 側に、誰の import で読まれたかがどう記録されるか（アクティビティログ / `ContainerRegistryRepositoryEvents` のどちらに、どの ID で出るか）は**要検証**。
- データプレーンのログ（`ContainerRegistryLoginEvents` / `ContainerRegistryRepositoryEvents`）を取るには診断設定で Log Analytics に送る。

### 5.8 その他の注意

- **ACR のロール割り当てモード**: ABAC モード（`rbac-abac`）の ACR では `AcrPull` / `AcrPush` / `Contributor` の**データ権限が効かない**。Data Importer は両モード対応なので、今回の構成ならモードを意識しなくてよい。将来 ABAC モードが既定になる予定。
- **Owner / Contributor で代用しない**: import は通るが、レジストリの設定変更・削除までできてしまう。
- **クロステナントは別の話**: テナントをまたぐと `--registry` によるリソース ID 指定は使えず、ユーザ名 / パスワード（SP シークレットやアクセストークン）が必要になる。また **public アクセス無効のソースからのクロステナント import は非対応**。
- 1 イメージあたりのマニフェスト数は最大 50。

---

## 6. 検証するときの観点（次のステップ案）

1. 両 ACR に Data Importer だけを持つユーザで、§4.3 のコマンドが成功するか（両 ACR とも public 無効 + trusted services ON の状態で）。
2. ソース側から Data Importer を外す → 失敗すること、エラーメッセージの内容。
3. 取り込み先側から外す → 失敗すること。
4. §5.1 のカスタムロール（ソース: `pull/read` + `read` のみ、取り込み先: `importImage/action` + `read` のみ）で通るか。
5. ソースを ABAC モードにして `Repository Reader` + リポジトリ条件で、許可したリポジトリだけ import できるか（§5.3）。
6. ソースで `exportPolicy=disabled` にしたときのエラー。
7. 条件付きアクセス（ネームドロケーション）を許可外の IP から試した場合の `az login` / `az acr import` の挙動。
8. ソース A 側のログに何が残るか。

---

## 出典

- [Import container images to a container registry — Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-import-images)
  - *"Your identity must have permissions to view and pull images, tags, and OCI referrers from the source registry (`Container Registry Data Importer and Data Reader` role assigned on the source registry)."*
  - *"Your identity must also have permissions to both read images and trigger imports on the target registry (`Container Registry Data Importer and Data Reader` role assigned on the target registry)."*
  - *"If public access is disabled, specify the source registry by resource ID instead of by registry login server name."*
  - *"Cross-tenant import isn't supported over public access disabled registry."*
- [Azure Container Registry Entra permissions and role assignments overview](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-rbac-built-in-roles-overview)
  - Data Importer: *"This role doesn't support Microsoft Entra ABAC conditions as the role is scoped to the registry level, granting permissions to import images into any repository in the registry."*
- [ACR roles directory reference](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-rbac-built-in-roles-directory-reference)
- [Azure ABAC repository permissions in ACR](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-rbac-abac-repository-permissions)
- [Allow trusted services to access a network-restricted container registry](https://learn.microsoft.com/en-us/azure/container-registry/allow-access-trusted-services)
  - trusted services 一覧: *"Azure Container Registry — Import images to or from a network-restricted Azure container registry"*
- [Disable artifact export (exportPolicy)](https://learn.microsoft.com/en-us/azure/container-registry/data-loss-prevention)
- ロール定義の実体: `az role definition list --name "Container Registry Data Importer and Data Reader"`（2026-10-19 取得）
- 関連: 本リポジトリの [`../cross_subscription_pull/README.md`](../cross_subscription_pull/README.md)（trusted services で private ソースから import できる件の経緯）
