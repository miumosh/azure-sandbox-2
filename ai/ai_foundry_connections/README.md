# AI Foundry (Hub) の外部リソース調査

AI Foundry 作成時に必要な外部リソース (Storage Account / Key Vault ほか) について、
次の 3 点を一次情報中心に調べた結果。

1. 必要な外部リソースと、その関係性
2. 外部リソースは専用・共有のどちらが推奨か、その理由
3. 外部リソースで何が行われるか (Key Vault で検知したアクティビティの説明を含む)

調査日: 2026-10-28 / 調査レベル (実機の追加検証はしていない。過去の検証結果は引用)

---

## 0. スコープ: 「AI Foundry」は 2 種類ある

| 呼び方 | ARM リソース型 | Storage / Key Vault | 本調査での扱い |
|---|---|---|---|
| **Hub ベース (classic)** | `Microsoft.MachineLearningServices/workspaces` (kind=`hub` / `project`) | **必須** (なければ自動作成) | **主対象** |
| **Foundry リソース (新)** | `Microsoft.CognitiveServices/accounts` (kind=`AIServices`) + `accounts/projects` | **不要** (既定は Microsoft 管理。BYO は任意) | 比較のために触れる |

検知したアクティビティ (Key Vault のアクセスポリシー更新、`KeyVaultLogging` 診断設定、
シークレット 3 つ) は **Hub ベース = Azure Machine Learning ワークスペースの挙動**であり、
新しい Foundry リソースでは起きない。
Hub ベースは Learn 上で「legacy support」と明記されている
([ai-resources](https://learn.microsoft.com/en-us/azure/foundry-classic/concepts/ai-resources))。

## 1. 結論サマリ

| 問い | 答え | 確度 |
|---|---|---|
| 必須の外部リソース | **Storage Account / Key Vault / Foundry (AI Services)**。ACR、App Insights + Log Analytics、AI Search は任意 | A |
| 関係性 | Hub が依存リソースを 1 セット持ち、配下の Project はそれを**継承して共有**する。Project 側では指定しない | A |
| 専用か共有か | **Hub 単位では専用が無難**。Project 間の共有は Hub の設計そのもの (Hub が分離を担う)。**Hub (ワークスペース) 間の共有は「サポートはされるが条件付き」** で、MS は「データ分離 + UAMI」を前提にしている | A + D (判断) |
| Key Vault に入るもの | 接続 (API キー / SAS 等) の資格情報、既定データストアの資格情報 | A |
| シークレット 3 つ | `workspaceblobstore` / `workspaceartifactstore` / `workspaceworkingdirectory` の資格情報 (既定データストア) | C (実機) + A (仕組み) |
| `KeyVaultLogging` 診断設定 | ワークスペース作成時に RP が自動追加。**2023 年 2 月に入った変更**で「特定シークレットの更新・削除を追跡するため」。作成時に無効化する手段はない。削除してもワークスペースには影響しない | B (MS 社員回答) |
| `Update Access Policy` | ワークスペース (Hub / Project) の**システム割り当て MI に Key Vault のデータ面権限を付与する**処理。MS は「全キー・シークレット・証明書へのアクセス」と記載 | A + C |

**確度の凡例**

| 記号 | 意味 |
|---|---|
| **A** | 一次情報: Microsoft Learn の公式ドキュメント |
| **B** | 一次情報に準ずる: Microsoft Q&A での MS 社員回答、MS/HashiCorp 公式リポジトリの Issue |
| **C** | このリポジトリでの実機観測 (`../ai_foundry`, `../ai_foundry_keyvault_relation`) |
| **D** | 上記からの推論、または第三者情報。検証が必要 |

## 2. ドキュメント構成

| ファイル | 内容 |
|---|---|
| [01_dependent-resources.md](01_dependent-resources.md) | 必要な外部リソースの一覧、役割、Hub / Project との関係、作成後の制約 |
| [02_shared-vs-dedicated.md](02_shared-vs-dedicated.md) | 専用・共有の推奨と理由、共有する場合の条件 |
| [03_keyvault-activities.md](03_keyvault-activities.md) | Key Vault で起きること (検知した 3 つのアクティビティの解説) |
| [04_storage-activities.md](04_storage-activities.md) | Storage Account で起きること (コンテナ、ロール、CORS、診断ログの受け皿) |
| [05_sources.md](05_sources.md) | 出典一覧 (確度、更新日付き) |

## 3. 未解決・要検証の点

- `KeyVaultLogging` の公式ドキュメント: 2023 年に MS 社員が「ドキュメントに追加される予定」と回答したが、
  2026-10 時点の Learn では見つけられなかった (D)。
- Key Vault の権限モデル (RBAC / アクセスポリシー) によって、RP の付与方法が
  「Key Vault Administrator のロール割り当て」と「アクセスポリシー更新」で切り替わるように見える。
  ただしこれは本リポジトリの 2 つの実機観測から推論したもので、公式の記述はない (C + D)。
  詳細は [03](03_keyvault-activities.md) を参照。
- アクセスポリシーで付与される具体的な権限セット (Get/List/Set/Delete など) は公式に列挙されていない。
  実機で `az keyvault show --query properties.accessPolicies` を確認するのが確実 (D)。
