# 05. 出典一覧

← [README](README.md)

参照日はすべて 2026-10-28。ms.date はページのメタデータ上の記事日付。

## A: Microsoft Learn (公式ドキュメント)

| # | タイトル | URL | ms.date | 主に使った箇所 |
|---|---|---|---|---|
| A1 | Hubs and hub-based project overview (classic) | https://learn.microsoft.com/en-us/azure/foundry-classic/concepts/ai-resources | 2025-12-24 | 依存リソース表、Project 間の分離方法 |
| A2 | What is a workspace? (Azure ML) | https://learn.microsoft.com/en-us/azure/machine-learning/concept-workspace?view=azureml-api-2 | 2026-02-10 | 関連リソースの用途、Storage の制約、「Share Azure resources」 |
| A3 | What is an Azure Machine Learning hub workspace? | https://learn.microsoft.com/en-us/azure/machine-learning/concept-hub-workspace?view=azureml-api-2 | 2026-03-26 | Hub → Project の継承・共有表 |
| A4 | Set up service authentication (Azure ML) | https://learn.microsoft.com/en-us/azure/machine-learning/how-to-identity-based-service-authentication?view=azureml-api-2 | 2026-01-22 | 共有時は UAMI + データ分離、データ分離の効果、UAMI に必要な KV 権限、資格情報型データストアの KV キャッシュ |
| A5 | Enterprise security and governance (Azure ML) | https://learn.microsoft.com/en-us/azure/machine-learning/concept-enterprise-security?view=azureml-api-2 | 2025-10-30 | MI の権限表 (KV: all keys, secrets, certificates)、「revoke しない」、Storage の注意 |
| A6 | Manage workspaces in portal or Python SDK (v2) | https://learn.microsoft.com/en-us/azure/machine-learning/how-to-manage-workspace?view=azureml-api-2 | 2026-01-28 | 制約、削除時の振る舞い、Storage アクセス方式 (Credential / Identity) |
| A7 | Role-based access control for Foundry (Hubs and Projects) (classic) | https://learn.microsoft.com/en-us/azure/foundry-classic/concepts/hub-rbac-foundry | 2025-12-31 | Azure AI Administrator (2024-11-19 以降) の定義 |
| A8 | Create a secure hub (classic) | https://learn.microsoft.com/en-us/azure/foundry-classic/how-to/create-secure-ai-hub | 2025-12-23 | ポータルでの Storage / Credential store の選択 |
| A9 | Microsoft Foundry architecture | https://learn.microsoft.com/en-us/azure/foundry/concepts/architecture | 2026-08-21 | 新 Foundry の Microsoft 管理ストレージ / KV |
| A10 | Set up an Azure Key Vault Connection (Foundry) | https://learn.microsoft.com/en-us/azure/foundry/how-to/set-up-key-vault-connection | 2026-08-14 | 新 Foundry の BYO KV の制約・ロール |
| A11 | Secure your Azure Key Vault | https://learn.microsoft.com/en-us/azure/key-vault/general/secure-key-vault | 2026-07-10 | 「1 アプリ・リージョン・環境ごとに 1 KV」、アクセスポリシー非推奨 |
| A12 | Assign an Azure Key Vault access policy | https://learn.microsoft.com/en-us/azure/key-vault/general/assign-access-policy | 2026-05-12 | 1024 エントリ上限、`vaults/write` で自分にデータ面権限を付与できる |
| A13 | Diagnostic settings in Azure Monitor | https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/diagnostic-settings | 2026-03-31 | 1 リソースあたり 5 設定、Storage 送信先の要件 |
| A14 | Enable Azure Key Vault logging | https://learn.microsoft.com/en-us/azure/key-vault/general/howto-logging | - | KV 診断ログの標準的な設定方法 |
| A15 | Regenerate storage account access keys (resync keys) | https://learn.microsoft.com/en-us/azure/machine-learning/how-to-change-storage-access-key | - | キーのローテーション後の再同期 (本文は未精読。リンクは A5 から辿ったもの) |

## B: 一次情報に準ずるもの

| # | 種別 | タイトル / URL | 日付 | 内容 |
|---|---|---|---|---|
| B1 | Microsoft Q&A (MS 社員回答) | [Provisioning of new workspace is adding a Key Vault diagnostic setting to the Storage Account](https://learn.microsoft.com/en-us/answers/questions/1250547/provisioning-of-new-workspace-is-adding-a-key-vaul) | 2023-04-20 / 回答 04-26 | `KeyVaultLogging` は 2023-02 の変更。目的・無効化不可・削除可 |
| B2 | GitHub Issue (HashiCorp azurerm) | [#22237 Key vault access policy for managed identity appears for no reason ...](https://github.com/hashicorp/terraform-provider-azurerm/issues/22237) | 2023-06-21 (Open) | ML ワークスペースの MI のアクセスポリシーが Terraform 管理外で再作成される |

## C: このリポジトリでの実機観測

| # | 場所 | 内容 |
|---|---|---|
| C1 | `../ai_foundry/README.md` §4.1 / `main.tf` | KV が RBAC モデルの場合の自動ロール付与 (Hub MI に Key Vault Administrator など)、409 |
| C2 | `../ai_foundry/README.md` §4.2 | Storage への CORS ルールの自動設定 |
| C3 | `../ai_foundry_keyvault_relation/README.md` §7、`results/*.md` | 自動作成される 3 つのシークレットの名前と contentType、データストアの認証種別、KV ファイアウォールの影響 |
| C4 | ユーザーの観測 (本調査の依頼内容) | シークレット 3 つ、`KeyVaultLogging` (Audit Logs / AllMetrics → Hub の Storage)、Hub / Project による `Update Access Policy` |

## D: 見つからなかったもの (調べたが一次情報なし)

- `KeyVaultLogging` の公式ドキュメント (B1 で「追加予定」とされたもの)
- ワークスペース RP が KV の権限モデル (RBAC / アクセスポリシー) によって付与方法を切り替える、という公式の記述
- RP が付与するアクセスポリシーの具体的な権限セット
- `workspaceartifactstore` / `workspaceworkingdirectory` の役割の公式説明
- Storage への CORS 自動設定の公式記述
- 新 Foundry リソース間で BYO KV を共有することの可否
