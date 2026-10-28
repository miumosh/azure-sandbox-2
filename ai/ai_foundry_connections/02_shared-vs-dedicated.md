# 02. 外部リソースは専用・共有どちらが推奨か

← [README](README.md)

## 1. 結論

| 共有の単位 | 推奨 | 確度 |
|---|---|---|
| **同じ Hub 配下の Project 間** | **共有する (そもそもそういう設計)**。Project は Hub の依存リソースを継承し、分離は Hub が担う | A |
| **Hub (ワークスペース) 間** | **専用を推奨**。共有は「サポートはされる」が、MS は **UAMI + データ分離** を前提条件としている | A (条件) + D (推奨の判断) |
| **AI Foundry 以外のシステムとの共有** | **専用を強く推奨**。業務データ用 Storage や他アプリの Key Vault を Hub の依存リソースにしない | A (根拠) + C + D |

要するに、**共有したいなら Hub を共有し、依存リソースを Hub 間で共有しない**という整理になる。
Hub は「同じセキュリティ境界・業務ドメインのチームが依存リソースを共有するための入れ物」として設計されている。

## 2. Microsoft の公式記述

### 2.1 共有は「許容されている」 **(A)**

[What is a workspace? - Organizing workspaces](https://learn.microsoft.com/en-us/azure/machine-learning/concept-workspace?view=azureml-api-2) (ms.date 2026-02-10):

> **Share Azure resources**: Workspaces require you to create several associated resources.
> Share these resources between workspaces to save repetitive setup steps.

> **Use hub workspaces for centralized governance**: A hub workspace groups multiple project workspaces
> with shared security settings, connections, and compute resources.

→ 共有の動機は「セットアップの手間を減らす」こと。セキュリティ上の推奨として書かれているわけではない。
同じページで、共有の受け皿として Hub を案内している。

### 2.2 共有するなら「UAMI + データ分離」 **(A)**

[Set up service authentication](https://learn.microsoft.com/en-us/azure/machine-learning/how-to-identity-based-service-authentication?view=azureml-api-2) (ms.date 2026-01-22) の表:

| シナリオ | 推奨 ID | 代替 |
|---|---|---|
| Multiple workspaces sharing resources | **User-assigned managed identity with data isolation** | System-assigned identity (**not recommended**) |

同じページの「Data isolation for shared resources」の要点:

- 複数のワークスペースで Storage / Key Vault / ACR を共有するときは `enableDataIsolation` を有効にして、
  名前の衝突を防ぎ、各ワークスペースが自分のデータにだけアクセスできるようにする
- **作成時にしか設定できず、後から有効化・無効化はできない**
- 既定値: `hub` = **有効**、`project` = 有効 (Hub から継承)、`default` (通常ワークスペース) = **無効**

| リソース | データ分離を有効にしたときの振る舞い |
|---|---|
| Storage | コンテナ名に GUID 接頭辞 (`{workspaceGUID}-azureml-blobstore`)、ワークスペース MI には **ABAC 条件付き**のデータ面ロール |
| Key Vault | **シークレット名に GUID 接頭辞** |
| ACR | イメージ名に GUID 接頭辞 |

→ Key Vault の「分離」は**名前の接頭辞**による。Key Vault のアクセス制御で区切っているわけではない (§3.1)。

### 2.3 Key Vault 一般のベストプラクティス **(A)**

[Secure your Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/secure-key-vault) (ms.date 2026-07-10):

> **Use one Key Vault per application, region, and environment** ...
> Key vaults define security boundaries for stored secrets. Grouping secrets into the same vault
> increases the *blast radius* of a security event ...

> **Don't use legacy access policies**: Legacy access policies have known security vulnerabilities
> and lack support for Privileged Identity Management (PIM).

### 2.4 Storage について **(A)**

[Enterprise security and governance](https://learn.microsoft.com/en-us/azure/machine-learning/concept-enterprise-security?view=azureml-api-2):

> Don't grant permission on the workspace's storage account to users that you don't want to access
> workspace computes or identities. The workspace's storage account contains code and executables that
> run on your workspace computes. Users with access to that storage account can edit or change code that
> runs in the context of the workspace, granting access to workspace data and credentials.

→ 他システムと Storage を共有して利用者が増えると、**ワークスペースのコンピュート上で動くコードを改ざんできる人**が増える。

## 3. 専用を推奨する理由 (公式記述と実機観測からの整理)

### 3.1 Key Vault: 分離が「API レベル」でしかない **(A + D)**

- Hub / Project の MI には「全キー・シークレット・証明書へのアクセス」が付く
  ([01 §2.3](01_dependent-resources.md))。
- アクセスポリシーは**ボールト全体**に効き、シークレット単位の制御はできない。
  RBAC でもワークスペースに自動で付くのは **Key Vault Administrator (ボールトスコープ)** だった (C)。
- そのため、Project 間・Hub 間の分離は「Azure ML の API が他の GUID のシークレットを返さない」ことで成り立っている
  (Learn の表現も「secrets can't be retrieved across projects **via APIs**」)。
- **Key Vault を共有すると、どの Hub / Project の MI も Key Vault に直接アクセスすれば他のシークレットを読める**。
  → ボールトを共有した数だけ影響範囲 (blast radius) が広がる。

### 3.2 Key Vault: Hub ごとに設定が上書き・追加される **(B + C + D)**

Hub を作るたびに RP が Key Vault に次の変更を加える ([03](03_keyvault-activities.md)):

- アクセスポリシーの追加 (Hub と Project ごと)
- 診断設定 `KeyVaultLogging` の追加 (送信先 = その Hub の Storage)

共有した場合に考えられる影響 (いずれも推論、D):

- **診断設定の上限**: 「Each resource can have up to five diagnostic settings.」
  ([Diagnostic settings in Azure Monitor - Destinations](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/diagnostic-settings#destinations), A)。
  Storage が違う Hub が同じ KV を共有すると、`KeyVaultLogging` の送信先の衝突や上限超過が起こりうる
  (同名設定が上書きされるのか、作成に失敗するのかは未検証)。
- **アクセスポリシーの上限**: 「Key vault supports up to 1024 access policy entries」
  ([Assign an Azure Key Vault access policy](https://learn.microsoft.com/en-us/azure/key-vault/general/assign-access-policy), A)。
  Project が増えるほど消費する。
- **ネットワーク設定の連動**: AI Foundry の RP は Microsoft 管理側の経路から KV のデータ面を叩くため、
  KV に `bypass = AzureServices` が必要 (`../ai_foundry_keyvault_relation`, C)。
  共有すると、他システムの都合で KV を閉じたときに Hub の接続が全滅する (逆も同じ)。

### 3.3 Storage: Hub が設定を書き換える **(C)**

`../ai_foundry/README.md` §4.2 の観測: Hub は紐づけた Storage に **Studio 用の CORS ルールを自動設定**する
(`https://ml.azure.com`、`https://*.ai.azure.com` など)。
業務用 Storage を共有すると、そのアカウントに**意図しないクロスオリジン許可が入る**。

### 3.4 Storage: 持ち込めないアカウントがある **(A)**

**階層型名前空間 (ADLS Gen2) と Premium は既定ストレージにできない**ため、
既存のデータレイクをそのまま Hub の依存リソースにすることはそもそもできない。
データレイクは「接続 / データストア」として参照するのが正しい使い方。

### 3.5 ライフサイクル **(A)**

ワークスペースを削除しても依存リソースは既定で残る。
共有していると「どの Hub のシークレット・コンテナか」の棚卸しが GUID 頼りになり、後片付けが難しい。

## 4. それでも共有する場合のチェックリスト

| # | 項目 | 根拠 |
|---|---|---|
| 1 | 作成時に `enableDataIsolation` が有効か確認する (Hub は既定で有効、後から変えられない) | A |
| 2 | ワークスペースの ID は **UAMI** にする (SAI は「not recommended」) | A |
| 3 | Key Vault は **RBAC モデル**にする (アクセスポリシーは非推奨) | A |
| 4 | KV の診断設定の数と `KeyVaultLogging` の送信先を確認する | B + D |
| 5 | KV のネットワークで `bypass = AzureServices` を維持する | C |
| 6 | Storage の CORS をインフラコードの管理対象から外す (`ignore_changes`) | C |
| 7 | Storage のデータ面権限を持つ人を最小限にする (コード改ざんのリスク) | A |

## 5. 参考: 新しい Foundry リソースの場合 **(A)**

- 既定では Storage / Key Vault を**顧客側に持たない** (Microsoft 管理)。専用・共有を議論する前提がない。
- BYO Key Vault は **Foundry リソース 1 つにつき接続 1 つ**で、その KV が「プロジェクトとリソース全体の接続シークレット」を管理する
  ([architecture](https://learn.microsoft.com/en-us/azure/foundry/concepts/architecture))。
- 複数の Foundry リソースで 1 つの KV を共有してよいかについては**公式の記述が見つからなかった**。
  §2.3 の一般則 (アプリ・環境・リージョンごとに 1 ボールト) に従うのが無難 (D)。
