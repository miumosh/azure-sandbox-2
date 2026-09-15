# 用語集 — 何がどれを指すのか

この領域は**同じ言葉が複数の実体を指す**ため、まずここで固定する。

---

## 1. 「AI Foundry」が指しうるもの (4 つ)

| 呼び方 | 実体 | ARM リソースか | Terraform |
|---|---|---|---|
| AI Foundry **ポータル** | `ai.azure.com` という Web サイト | ❌ ただの UI | — |
| AI Foundry **Hub** (v1) | `Microsoft.MachineLearningServices/workspaces` (kind=**Hub**) | ✅ | `azurerm_ai_foundry` |
| AI Foundry **リソース / アカウント** (v2) | `Microsoft.CognitiveServices/accounts` (kind=**AIServices**) | ✅ | `azurerm_cognitive_account` |
| AI Foundry **プロジェクト** | **v1 と v2 で別物が 2 種類ある** (§2) | ✅ | 下表参照 |

> **ポータルは v1 系と v2 系のプロジェクトを同じ一覧に並べる。**
> 画面が同じでも裏のリソースは別物になりうる。
> URL の `Microsoft.CognitiveServices` / `Microsoft.MachineLearningServices` で判別する。

---

## 2. 「プロジェクト」が指しうるもの (2 つ)

| | **v1 プロジェクト** | **v2 プロジェクト** |
|---|---|---|
| ARM 種別 | `Microsoft.MachineLearningServices/workspaces` (kind=Project) | `Microsoft.CognitiveServices/accounts/projects` |
| 親 | Hub | **AI Services アカウント** |
| 関係 | 別リソース。Hub から connection を張る | **入れ子**。親の部品なので接続不要 |
| ネットワーク制限の支配元 | 自身の `publicNetworkAccess` | **親アカウント**の設定 |
| Terraform | `azurerm_ai_foundry_project` | `azurerm_cognitive_account_project` |
| 本構成での名前 | `aifp-aissbx` | `proj-aissbx` |

---

## 3. 「閉域化」が指しうるもの (2 方向 × 3 レイヤー)

### 3.1 方向

| | 設定 | 制御するもの | 対象リソース |
|---|---|---|---|
| **受信 (inbound)** | `public_network_access` + Private Endpoint | **誰がそのリソースに入ってこられるか** | Hub / アカウント / Storage / Key Vault それぞれ |
| **送信 (outbound)** | v1: `managed_network` / v2: `network_injection` | **その中で動く計算リソースがどこへ出ていけるか** | Hub またはアカウント |

**この 2 つは互いの代替にならない。** PE をいくら足しても送信は制御できない。

### 3.2 レイヤー (Storage を閉じるときに分けて考える)

| 層 | 設定 | 問い | いつ効くか |
|---|---|---|---|
| ① Storage の受信 | Storage の `public_network_access_enabled = false` + PE | 誰が Storage に入れるか | 常時 |
| ② Hub / アカウントの受信 | `public_network_access = "Disabled"` + PE | 誰が Hub に入れるか | 常時 |
| ③ Hub / アカウントの送信 | `managed_network` / `network_injection` | 計算リソースが Storage へどう出るか | **実行時のみ** |

①と②は独立。**③は①をやったときに初めて問題になり、リソース作成時には効かない。**

---

## 4. 「ネットワーク」が指しうるもの

| 用語 | 何か | 誰の VNet か | あなたが管理するか |
|---|---|---|---|
| **Private Endpoint (PE)** | リソースへの受信口。あなたの VNet に NIC が生える | あなたの | ✅ |
| **マネージド PE** | `managed_network` (v1) が Microsoft 側 VNet に自動生成する PE | **Microsoft の** | ❌ outbound rules として見えるだけ |
| **managed_network / マネージド VNet** (v1) | Hub 専用の VNet を Microsoft 管理サブスクに作る | **Microsoft の** | ❌ 中身は不可視 |
| **network injection** (v2) | Agent のコンテナを**あなたの**委任サブネットに注入する | **あなたの** | ✅ サブネットとして見える |
| VNet 統合 (App Service 等) | 別サービスの機能。**上記とは無関係** | あなたの | ✅ |

---

## 5. 「プレーン」— 閉域化の影響範囲を決める最重要の区別

| | コントロールプレーン | データプレーン |
|---|---|---|
| ホスト | `management.azure.com` | `<account>.openai.azure.com` など |
| 何をするか | リソースの作成・設定・一覧 | 推論・ファイル操作・プロジェクト操作 |
| **`publicNetworkAccess = Disabled` の影響** | **受けない** | **受ける** |
| 使うもの | Azure ポータル / `az` / Terraform | AI Foundry ポータル / SDK |

**これが「Azure ポータルは使えるが AI Foundry ポータルは使えない」の理由。**
モデルのデプロイはコントロールプレーン操作なので、閉域化後も VNet 外からできる。

| 操作 | プレーン | 閉域後・VNet 外から |
|---|---|---|
| リソース作成 / 設定変更 | コントロール | ✅ |
| **モデルのデプロイ作成・削除** | コントロール | ✅ |
| Storage の SAS / キー取得 (`listKeys`) | コントロール | ✅ |
| 推論 (chat/completions) | データ | ❌ 403 |
| Foundry プロジェクトの一覧 / Playground | データ | ❌ 403 |
| Key Vault の Secret 読み書き | データ | ❌ |
| Blob の読み書き | データ | ❌ |

---

## 6. ホスト名のサフィックス — kind ごとに引くものが違う

| サフィックス | 使う SDK / 用途 | Private DNS Zone |
|---|---|---|
| `<sub>.cognitiveservices.azure.com` | Speech / Vision / Language / Content Safety / 各種 REST | `privatelink.cognitiveservices.azure.com` |
| `<sub>.openai.azure.com` | Azure OpenAI SDK | `privatelink.openai.azure.com` |
| `<sub>.services.ai.azure.com` | Azure AI Inference SDK / Foundry Projects SDK | `privatelink.services.ai.azure.com` |
| `<guid>.workspace.<region>.api.azureml.ms` | v1 Hub のデータ面 | `privatelink.api.azureml.ms` |
| `ml-<hub>-<region>-<guid>.<region>.notebooks.azure.net` | v1 Hub のノートブック | `privatelink.notebooks.azure.net` |
| `<name>.privatelink.<suffix>` | **内部名。呼んではいけない** (TLS SAN 外) | — |

| kind | 引かれるサフィックス | 必要なゾーン数 |
|---|---|---|
| `SpeechServices` | cognitiveservices | 1 |
| `OpenAI` | openai + cognitiveservices | 2 |
| `AIServices` | services.ai + openai + cognitiveservices | 3 |

---

## 7. HTTP ステータスの読み方 (切り分けの要)

| ステータス | 本文 | 意味 |
|---|---|---|
| **403** | `Public access is disabled. Please configure private endpoint.` | **ネットワーク遮断。**閉域化が効いている |
| **401** | `audience is incorrect (https://ai.azure.com)` | **トークンのオーディエンス違い。**ネットワークは無罪 |
| 401 / 404 (その他) | — | ネットワークは通ってアプリ層まで到達 |
| **200 (ルートパス `/`)** | — | **何も意味しない。**閉域でも 200 を返す |
| 000 (curl) | — | TLS エラー。`*.privatelink.*` の内部名を叩いていないか |

---

## 8. Terraform リソース早見表

| やりたいこと | リソース |
|---|---|
| v2 の AI Foundry / AI Services / OpenAI / Speech アカウント | `azurerm_cognitive_account` (`kind` で切替) |
| v2 のプロジェクト | `azurerm_cognitive_account_project` |
| モデルのデプロイ | `azurerm_cognitive_deployment` |
| v1 の Hub | `azurerm_ai_foundry` |
| v1 のプロジェクト | `azurerm_ai_foundry_project` |
| 受信の閉域化 | `public_network_access_enabled = false` + `azurerm_private_endpoint` |
| 送信の閉域化 (v1) | `azurerm_ai_foundry` の `managed_network` ブロック |
| 送信の閉域化 (v2) | `azurerm_cognitive_account` の `network_injection` ブロック |
| 名前解決 | `azurerm_private_dns_zone` + `azurerm_private_dns_zone_virtual_network_link` |

| PE の subresource | 対象 |
|---|---|
| `account` | Cognitive アカウント全般 (v2 の Foundry 含む) |
| `amlworkspace` | v1 Hub |
| `blob` / `file` | Storage |
| `vault` | Key Vault |

---

## 9. 紛らわしい設定名の対比

| | AI Services | Storage |
|---|---|---|
| ブロック名 | **`network_acls`** | **`network_rules`** |
| `bypass` の型 | 単一 `string` (`AzureServices` / `None`) | `set(string)` (`Logging` / `Metrics` / `AzureServices` / `None`) |
| ブロック省略時に ARM へ送る値 | **何も送らない** | `defaultAction = Allow` 等を**明示送信** |
| 実効的な既定 | 全ネットワーク許可 | 全ネットワーク許可 |
| 本リポジトリの変数既定 | `Deny` | `Deny` |

> **`public_network_access_enabled = false` にした時点で `network_acls.default_action` は
> 公開経路の判定に効かない。** 上位ゲートが閉じていれば下位は評価対象がない。
