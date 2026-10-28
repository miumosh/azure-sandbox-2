# 03. Key Vault で行われること

← [README](README.md)

Hub ベースの AI Foundry (= Azure ML ワークスペース) を作ると、紐づけた Key Vault に対して
Azure ML のリソースプロバイダ (RP) が次の 3 つを自動で行う。

## 0. 検知した 3 つのアクティビティの要約

| # | アクティビティ | 実行者 | 目的 | 消してよいか | 確度 |
|---|---|---|---|---|---|
| ① | シークレットが 3 つ作られる | RP (Hub の作成処理) | 既定データストア (`workspaceblobstore` / `workspaceartifactstore` / `workspaceworkingdirectory`) の **Storage 資格情報 (SAS / アカウントキー) を保存**する | **不可**。消すと既定データストアが使えなくなる | C (実機) + A (仕組み) |
| ② | 診断設定 `KeyVaultLogging` が作られる (送信先 = Hub の Storage、AuditEvent + AllMetrics) | RP | 「特定のシークレットの更新・削除を顧客が追跡できるようにする」(2023-02 の変更) | **可**。ワークスペースには影響しない。ただし KV の監査ログはそこに出なくなる | B |
| ③ | `Update Access Policy` (開始者 = Hub と Project) | Hub / Project のシステム割り当て MI | **自分の MI に KV のデータ面権限を付与する** (「全キー・シークレット・証明書へのアクセス」) | **不可**。消すと接続の解決などが失敗する (resync keys で復旧可能) | A + C |

---

## 1. アクティビティ ①: シークレットが 3 つ作られる

### 1.1 中身 **(C)**

`../ai_foundry_keyvault_relation` の実機検証 (2026-09-16) で確認したシークレット:

| シークレット名 | contentType | 対応する既定データストア | 認証種別 |
|---|---|---|---|
| `<GUID>-workspaceblobstore00010101000000000` | `application/vnd.ms-StorageAccountAccessKey` | `workspaceblobstore` | **SAS** |
| `<GUID>-workspaceartifactstore00010101000000000` | 同上 | `workspaceartifactstore` | **SAS** |
| `<GUID>-workspaceworkingdirectory00010101000000000` | 同上 | `workspaceworkingdirectory` | **AccountKey** |

- 接頭辞の `<GUID>` は**ワークスペース ID**。Hub / Project では「データ分離」が既定で有効なので、
  シークレット名に GUID が付く。 **(A)**
  ([identity-based auth - Data isolation](https://learn.microsoft.com/en-us/azure/machine-learning/how-to-identity-based-service-authentication?view=azureml-api-2#data-isolation-for-shared-resources))
- 末尾の `00010101000000000` は .NET の `DateTime.MinValue` (0001-01-01) に見えるが、意味は公式に説明されていない。 **(D)**
- 観測では Project を作ってもシークレットは増えず、3 つのままだった。
  Project 単位で API キーや SAS の接続を作ると `<ProjectのworkspaceId>-<接続名>` が追加される
  (contentType `WorkspaceConnectionSecret`)。 **(C)**

### 1.2 なぜ Key Vault に入るのか **(A)**

[Set up service authentication](https://learn.microsoft.com/en-us/azure/machine-learning/how-to-identity-based-service-authentication?view=azureml-api-2) より:

> datastores that use **credential-based authentication** cache connection information, like your storage
> account key or SAS token, in the key vault that's associated with the workspace. This approach has the
> limitation that other workspace users with sufficient permissions can retrieve those credentials ...

- 既定データストアが**資格情報ベース (SAS / アカウントキー)** で作られるため、その実体が KV に保存される。
- Hub 作成時の Identity 設定に「Storage account access: **Credential-based** / **Identity-based**」の選択肢がある。
  Identity-based にするとワークスペース MI に Storage Blob Data Contributor が必要になる
  ([how-to-manage-workspace - Identity](https://learn.microsoft.com/en-us/azure/machine-learning/how-to-manage-workspace?view=azureml-api-2))。 **(A)**
  - Identity-based にしたときにこの 3 つのシークレットが作られなくなるかは**未検証** (D)。
- 既定データストアの `workspaceblobstore` (Blob) と `workspacefilestore` (File share) は公式ドキュメントに名前が出てくる。
  `workspaceartifactstore` / `workspaceworkingdirectory` の役割は公式の説明が見つからなかった。
  名前と認証方式から、前者は成果物用の Blob、後者はコンピュートインスタンスのノートブックなどを置く File share だと推測している (D)。

### 1.3 運用上の注意

| 事象 | 影響 | 確度 |
|---|---|---|
| Storage のアカウントキーをローテーションした | KV のキャッシュが古くなる。**resync keys** 操作 ([how-to-change-storage-access-key](https://learn.microsoft.com/en-us/azure/machine-learning/how-to-change-storage-access-key)) で同期する | A |
| Storage の共有キーアクセスを無効化した (`allowSharedKeyAccess=false`) | SAS / AccountKey の既定データストアが使えなくなるおそれがある。Identity-based への切り替えが必要 | D |
| KV のファイアウォールで `bypass = None` にした | RP が KV を読めず、**既定データストアも含めて資格情報を解決できなくなる** (エラー文言は RBAC の問題に見えるが、実体は `ForbiddenByFirewall`) | C |
| シークレットを手動で削除した | 既定データストアが使えなくなる | D (仕組みからの推論) |

---

## 2. アクティビティ ②: 診断設定 `KeyVaultLogging`

### 2.1 一次情報 **(B)**

公式ドキュメントには記載がない。唯一の一次に近い情報は Microsoft Q&A の MS 社員 (モデレーター) の回答。

出典: [Provisioning of new workspace is adding a Key Vault diagnostic setting to the Storage Account](https://learn.microsoft.com/en-us/answers/questions/1250547/provisioning-of-new-workspace-is-adding-a-key-vaul)

- 質問 (2023-04-20、ユーザー): ポータルでも Bicep でも、Azure ML ワークスペースを作ると Key Vault に
  `KeyVaultLogging` という診断設定ができ、送信先が Storage Account になる。API 2022-05-01 から 2022-12-01-preview まで同じ。
  Bicep / ARM / Terraform から無効化できず、削除してもテンプレートを再実行すると復活する。
- MS 社員の回答 (2023-04-26、要約):
  > this change was done in **February** to allow customers to **track down information related to updates and deletions of certain secrets**.
  > This change was not documented in public documentation, and this should be added to the documentation soon.
  > Also, there is **no option to disable** the same during workspace creation ... edit the settings or **delete it if not required**.
  > **This should not affect the ML workspace** but activity logging of KV will be lost.
- 「無効化オプションは今後出るか」という追加の質問には回答がない (2026-10 時点で未解決)。

### 2.2 観測された内容と意味

| 項目 | 観測値 (ユーザー提供) | 解説 | 確度 |
|---|---|---|---|
| 名前 | `KeyVaultLogging` | 固定名 | B + C |
| ログ | Audit Logs | カテゴリグループ `audit` (KV では `AuditEvent` がこれに当たる)。シークレットの取得・作成・削除などのデータ面操作が記録される | A ([Key Vault logging](https://learn.microsoft.com/en-us/azure/key-vault/general/logging)) |
| メトリック | AllMetrics | KV のプラットフォームメトリック | A |
| 送信先 | AI Foundry に紐づけた Storage Account | Storage には `insights-logs-auditevent` / `insights-metrics-pt1m` というコンテナで書き込まれる (Azure Monitor の Storage 送信の標準動作) | A ([howto-logging](https://learn.microsoft.com/en-us/azure/key-vault/general/howto-logging)) + D |

### 2.3 影響と対処

| 観点 | 内容 | 確度 |
|---|---|---|
| コスト・重複 | 組織で Log Analytics に診断ログを集めている場合、**同じログが Storage にも重複して溜まる**。保持ポリシーがないので増え続ける | B (質問者の指摘) + D |
| 削除 | 削除してもワークスペースには影響しない | B |
| 再出現 | テンプレート (ワークスペース) を再デプロイすると**再作成される** | B |
| IaC ドリフト | Terraform 等で KV の診断設定を管理していなくても、Azure 側に「管理外の設定」が増える。同名の設定をコードで宣言すると取り合いになる可能性がある | D |
| 診断設定の上限 | 1 リソースあたり最大 5 つ。Azure Policy (DeployIfNotExists) でも診断設定を足している組織では枠を消費する | A ([diagnostic-settings](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/diagnostic-settings#destinations)) |
| Storage のネットワーク | 送信先 Storage にファイアウォールがある場合、「**Allow trusted Microsoft services**」を許可しないと診断ログは書き込めない。Storage は監視対象 (KV) と**同じリージョン**である必要がある | A (同上) |
| 開始者 | アクティビティログ上の開始者は**未確認**。Azure AI Administrator ロールには `Microsoft.Insights/diagnosticSettings/*` が含まれるので、Hub MI か RP が作っていると考えられる | A (ロール定義) + D |

---

## 3. アクティビティ ③: `Update Access Policy` (Hub / Project が開始者)

### 3.1 何をしているか **(A + C)**

[Enterprise security and governance](https://learn.microsoft.com/en-us/azure/machine-learning/concept-enterprise-security?view=azureml-api-2) より、
ワークスペースのシステム割り当て MI が関連リソースに持つ権限:

| Resource | Permissions |
|---|---|
| Key vault | **Access to all keys, secrets, certificates** |

> Don't revoke the access of the managed identity to the resources mentioned in the preceding table.
> You can restore access by using the resync keys operation.

- Key Vault が**アクセスポリシーモデル**だと、この権限は「アクセスポリシーへのエントリ追加」= `Update Access Policy`
  (`Microsoft.KeyVault/vaults/accessPolicies/write`) として付与される。
- **Hub と Project はそれぞれ別のトップレベルリソースで、それぞれ MI を持つ**。
  Project の MI も自分のシークレット (Project 単位の接続など) を読み書きする必要があるため、**両方の MI 分**のエントリが追加される。
  → 開始者が Hub と Project の 2 つだったのはこのため。
  - 「Key vault: ... Project workspaces identities can only access their own secrets.」
    ([concept-hub-workspace](https://learn.microsoft.com/en-us/azure/machine-learning/concept-hub-workspace?view=azureml-api-2))
- 具体的な権限セット (Get / List / Set / Delete / Recover / Backup / Restore など) は公式に列挙されていない。
  確認するコマンド (D):
  ```bash
  az keyvault show -n <kv> --query "properties.accessPolicies[].{oid:objectId, secrets:permissions.secrets, keys:permissions.keys, certs:permissions.certificates}" -o json
  # objectId を Hub / Project の MI と突き合わせる
  az ml workspace show -n <hub or project> -g <rg> --query identity.principal_id -o tsv
  ```

### 3.2 なぜ MI 自身がアクセスポリシーを書き換えられるのか **(A)**

- 2024-11-19 以降に作られた Hub の MI には **Azure AI Administrator** が付く。
  そのアクションに **`Microsoft.KeyVault/*`** が含まれる
  ([hub-rbac-foundry](https://learn.microsoft.com/en-us/azure/foundry-classic/concepts/hub-rbac-foundry))。
- Key Vault の公式ドキュメントは、アクセスポリシーモデルの特性として次のように警告している
  ([assign-access-policy](https://learn.microsoft.com/en-us/azure/key-vault/general/assign-access-policy)):
  > With the Access Policy permission model, users with the `Contributor`, `Key Vault Contributor`, or any role that
  > includes `Microsoft.KeyVault/vaults/write` permissions **can grant themselves data plane access** by configuring a Key Vault access policy.
- つまり、**コントロールプレーンの権限 (`vaults/write`) を持つ MI が、自分にデータ面の権限を付与している**、という構図。

### 3.3 注意: Project 間の分離は Key Vault の権限ではなく API で担保されている **(A + D)**

- アクセスポリシーは**ボールト全体**に効く。シークレット単位でのアクセス制御はできない。
- そのため Project A の MI は、技術的には Key Vault に直接アクセスすれば Project B のシークレットも読める (D)。
- Learn の表現も「For data isolation, secrets **can't be retrieved across projects via APIs**」
  ([ai-resources](https://learn.microsoft.com/en-us/azure/foundry-classic/concepts/ai-resources)) で、
  分離は Azure ML の API と命名規則 (GUID 接頭辞) によるもの。
- ただし MI のトークンは利用者には取得できない
  (「Users can't access the identity token」, [concept-enterprise-security](https://learn.microsoft.com/en-us/azure/machine-learning/concept-enterprise-security?view=azureml-api-2))。
  そのため実際のリスクは「KV に直接権限を持つ人間・他システム」の側にある。→ [02](02_shared-vs-dedicated.md) の「KV は専用」の根拠。

### 3.4 RBAC モデルの Key Vault の場合 **(C + D)**

- `../ai_foundry` (Key Vault は RBAC モデル) の実機観測では、アクセスポリシーではなく
  **Hub MI に `Key Vault Administrator` (KV スコープ) のロール割り当て**が自動で作られた。
- 「KV の権限モデルによって、RP がアクセスポリシー更新とロール割り当てを切り替えている」ように見えるが、
  公式の記述は見つからなかった (C から推論、D)。
- 利用者側で UAMI を使う場合は自分で権限を付ける必要がある。必要な権限 (A, [identity-based auth](https://learn.microsoft.com/en-us/azure/machine-learning/how-to-identity-based-service-authentication?view=azureml-api-2)):
  - RBAC モデル: Contributor (コントロールプレーン) + **Key Vault Administrator** (データ面)
  - アクセスポリシーモデル: Contributor + **purge を除く任意のアクセスポリシー権限**

### 3.5 IaC (Terraform) での落とし穴 **(B + C + D)**

| 事象 | 内容 | 確度 |
|---|---|---|
| インラインの `access_policy` で上書きされる | `azurerm_key_vault` の `access_policy` ブロックで KV のポリシーを管理していると、次の apply で RP が足したエントリが**削除され、ワークスペースが壊れる**。インラインでは管理しない、`ignore_changes = [access_policy]` を付ける、または RBAC モデルにする | D (azurerm の一般的な挙動) |
| ポリシーが「勝手に復活」する | ワークスペースの MI 用のアクセスポリシーを Terraform から外しても、Azure 側が**再作成する**という報告がある (未解決) | B ([terraform-provider-azurerm #22237](https://github.com/hashicorp/terraform-provider-azurerm/issues/22237), 2023-06) |
| ロール割り当てが 409 になる | RBAC モデルで、自動付与と同じロール割り当てを宣言すると `RoleAssignmentExists` | C (`../ai_foundry/README.md` §4.1) |
| 推奨 | KV は **RBAC モデル**にする (アクセスポリシーは「legacy」「known security vulnerabilities」と公式が明記) | A ([secure-key-vault](https://learn.microsoft.com/en-us/azure/key-vault/general/secure-key-vault)) |

---

## 4. 確認用コマンド

```bash
RG=<rg>; KV=<kv>

# ① シークレット (contentType も確認)
az keyvault secret list --vault-name $KV --query "[].{name:name, type:contentType}" -o table

# ② 診断設定
az monitor diagnostic-settings list --resource $(az keyvault show -n $KV --query id -o tsv) -o json

# ③ アクセスポリシー / 権限モデル
az keyvault show -n $KV --query "{rbac:properties.enableRbacAuthorization, policies:properties.accessPolicies[].objectId}"

# ③ 開始者の確認 (アクティビティログ)
az monitor activity-log list --resource-id $(az keyvault show -n $KV --query id -o tsv) --offset 1d \
  --query "[].{op:operationName.value, caller:caller, time:eventTimestamp}" -o table
```
