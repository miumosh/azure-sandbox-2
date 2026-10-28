# 04. Storage Account で行われること

← [README](README.md)

## 0. 要約

| # | 何が行われるか | 実行者 | 確度 |
|---|---|---|---|
| ① | 既定データストア用のコンテナ / ファイル共有の作成 (`{workspaceGUID}-azureml-blobstore` など) | RP | A |
| ② | Hub / Project の MI への**データ面ロール付与** (ABAC 条件付き) | RP | A + C |
| ③ | Studio / Foundry ポータル用の **CORS ルールの自動設定** | RP | C |
| ④ | Key Vault の診断ログ (`KeyVaultLogging`) の**送信先**になる | RP (KV 側の設定) | B |
| ⑤ | 既定データストアの資格情報 (SAS / アカウントキー) が発行され、**Key Vault に保存**される | RP | C + A |

## 1. コンテナとデータ分離 **(A)**

[concept-hub-workspace](https://learn.microsoft.com/en-us/azure/machine-learning/concept-hub-workspace?view=azureml-api-2):

> Project workspaces use designated containers starting with a prefix {workspaceGUID}, and have a conditional
> Azure Attribute Based Access role assignment for the workspace identity for accessing these containers only.

[identity-based auth - Data isolation](https://learn.microsoft.com/en-us/azure/machine-learning/how-to-identity-based-service-authentication?view=azureml-api-2#data-isolation-for-shared-resources):

> Container names are prefixed with the workspace GUID (for example, `{workspaceGUID}-azureml-blobstore`).
> The workspace managed identity receives a data plane role assignment with an Azure attribute-based access control (ABAC)
> condition that limits access to only the workspace's specific containers.

保存されるもの ([ai-resources](https://learn.microsoft.com/en-us/azure/foundry-classic/concepts/ai-resources)、[concept-workspace](https://learn.microsoft.com/en-us/azure/machine-learning/concept-workspace?view=azureml-api-2)):
flow、評価結果、ジョブログ、アップロードしたデータ、コンピュートインスタンスのノートブックなど。

## 2. ロール付与

| 情報源 | 内容 | 確度 |
|---|---|---|
| [concept-enterprise-security](https://learn.microsoft.com/en-us/azure/machine-learning/concept-enterprise-security?view=azureml-api-2) | ワークスペース MI → Storage: **Storage Blob Data Contributor** | A |
| `../ai_foundry/README.md` §4.1 | Hub MI: Storage Blob Data Contributor / **Storage File Data Privileged Contributor**。Project MI: さらに Storage Account Contributor / Reader など | C |

- Terraform で同じロール割り当てを宣言すると 409 になる (C)。
- 公式の注意 (A, concept-enterprise-security):
  ワークスペースの Storage には**コンピュート上で実行されるコードや実行ファイル**が置かれる。
  Storage に権限を持つ人はそのコードを改ざんでき、ワークスペースのデータや資格情報にアクセスできてしまう。
  → Storage への権限付与は最小限にする。

## 3. CORS ルールの自動設定 **(C)**

`../ai_foundry/README.md` §4.2 の観測。公式ドキュメントには明記がない (Q&A では「AI Studio を使うなら Storage に CORS が必要」という回答がある)。

```
origins: https://mlworkspace.azure.ai, https://ml.azure.com, https://*.ml.azure.com,
         https://ai.azure.com, https://*.ai.azure.com
```

- ブラウザから Storage のデータ面へ直接アクセスする (Studio のファイルブラウザ、データのアップロード/プレビュー) ために使われる。
- IaC で `blob_properties.cors_rule` を管理していると**毎回削除しようとし、Studio が壊れ、Azure が戻す**という差分ループになる。
  → `ignore_changes = [blob_properties[0].cors_rule]` で管理対象から外す。

## 4. Key Vault 診断ログの送信先 **(B + A)**

[03 §2](03_keyvault-activities.md) の `KeyVaultLogging` の送信先がこの Storage になる。

- 書き込み先コンテナ: `insights-logs-auditevent` (AuditEvent)、`insights-metrics-pt1m` (AllMetrics) (A: Azure Monitor の標準動作)
- 保持ポリシーは自動では付かない。ライフサイクル管理ポリシーを設定しないと増え続ける (D)
- Storage にファイアウォールを設定する場合は「**Allow trusted Microsoft services**」が必要
  ([diagnostic-settings](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/diagnostic-settings#destinations), A)

## 5. 持ち込める Storage の制約 (再掲) **(A)**

- 不可: `BlobStorage` 種別 / Premium / **階層型名前空間 (ADLS Gen2)**
- 別サブスクリプションの場合は `Microsoft.MachineLearningServices` の登録が必要
- 「Credential-based」か「Identity-based」かを作成時に選ぶ (Identity-based は MI に Storage Blob Data Contributor が必要)

## 6. 確認用コマンド

```bash
SA=<storage>; RG=<rg>
az storage container list --account-name $SA --auth-mode login --query "[].name" -o tsv
az storage share list --account-name $SA --auth-mode login --query "[].name" -o tsv 2>/dev/null
az storage account blob-service-properties show -n $SA -g $RG --query cors
az role assignment list --scope $(az storage account show -n $SA -g $RG --query id -o tsv) \
  --query "[].{role:roleDefinitionName, principal:principalId, condition:condition}" -o json
```
