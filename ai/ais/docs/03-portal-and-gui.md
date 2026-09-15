# GUI (ポータル) は閉域化後も操作できるか

**結論を先に。「ポータル」と一括りにできない。ARM を叩くポータルは閉域化後も
インターネットから普通に使え、データプレーンを叩くポータルは使えなくなる。**

| ポータル | URL | 叩く経路 | 閉域化後・VNet 外から | 閉域化後・VNet 内から |
|---|---|---|---|---|
| **Azure ポータル** | `portal.azure.com` | ARM (コントロールプレーン) | ✅ **そのまま使える** | ✅ 使える |
| **AI Foundry ポータル** | `ai.azure.com` | データプレーン | ❌ 403 | ✅ 使える |
| Azure ML Studio | `ml.azure.com` | データプレーン | ❌ | ⚠️ (§4) |
| **Speech Studio** | `speech.microsoft.com` | データプレーン | ❌ | ❌ **VNet 内でも不可** (§5) |

---

## 1. なぜ分かれるのか — 2 つの面

Azure のリソース操作には**まったく別の 2 経路**がある。
`publicNetworkAccess = Disabled` が閉じるのは**データプレーンだけ**。

```
                                   ┌──────────────────────────────┐
  あなたのブラウザ / terraform / az │  management.azure.com (ARM)  │
       ──────────────────────────► │  = コントロールプレーン        │
                                   │  リソースの作成・設定・一覧     │
                                   │  publicNetworkAccess の影響なし│
                                   └───────────┬──────────────────┘
                                               │ 設定を書く
                                               ▼
                                   ┌──────────────────────────────┐
  あなたのブラウザ / SDK            │  <account>.openai.azure.com  │
       ──────────────────X───────► │  <account>.services.ai...    │
       403 Public access is        │  = データプレーン              │
           disabled                │  推論・ファイル・プロジェクト操作│
                                   │  publicNetworkAccess が閉じる  │
                                   └──────────────────────────────┘
                                               ▲
  VNet 内の VM ───── Private Endpoint ─────────┘
```

**Azure ポータルはリソース管理画面としては ARM しか叩かない。**
だから「Networking を Disabled にした瞬間にポータルから何も見えなくなる」ことはない。

一方 **AI Foundry ポータルは「AI を使うための画面」**であり、
モデル一覧・Playground・プロジェクトのファイル・評価結果はすべてデータプレーン。
だから閉じた瞬間に届かなくなる。

---

## 2. 実測 (2026-09-15 / public 無効の状態で計測)

### 2.1 コントロールプレーン (Azure ポータルが使う経路)

**VNet 外の実行端末から、すべて 200。**

| 操作 | エンドポイント | HTTP |
|---|---|---|
| AIServices アカウント取得 | `management.azure.com/.../accounts/<name>` | **200** |
| **モデルデプロイ一覧** | `management.azure.com/.../accounts/<name>/deployments` | **200** |
| v2 プロジェクト一覧 | `management.azure.com/.../accounts/<name>/projects` | **200** |
| Hub (AML workspace) 取得 | `management.azure.com/.../workspaces/aif-aissbx` | **200** |

さらに強い証拠として、**このリポジトリの Terraform は VNet 外の端末から
public 無効のアカウントに対してモデルをデプロイできている**:

```
azurerm_cognitive_deployment.aiservices[0]: Creation complete after 15s
  .../accounts/ais-aissbx-xxxxx/deployments/gpt-5-4-mini
azurerm_cognitive_deployment.openai[0]: Creation complete
  .../accounts/oai-aissbx-xxxxx/deployments/gpt-5-4-mini
```

`azurerm_cognitive_deployment` は ARM を叩くだけなので、閉域化の影響を受けない。
**同じことを Azure ポータルの GUI からもできる**（裏で同じ ARM を呼ぶだけ）。

> ### ✅ 「AI Foundry であればモデルのデプロイ等」への回答
>
> **モデルのデプロイは、閉域化後も VNet 外の手元のブラウザから Azure ポータルで普通にできる。**
> Azure ポータル → 対象の AI Services / OpenAI リソース →
> **「モデル デプロイ」→「デプロイの管理」** から作成・削除・容量変更が可能。
>
> できなくなるのは **AI Foundry ポータル (ai.azure.com) 側のデプロイ画面**のほう。
> 同じ「モデルをデプロイする」でも、どちらの画面から行うかで可否が変わる。

### 2.2 データプレーン (AI Foundry ポータルが使う経路)

| エンドポイント | VNet 外 | VNet 内 (probe VM) |
|---|---|---|
| `<ais>.services.ai.azure.com/api/projects/<proj>/deployments` | **403** | **200** |
| `<ais>.services.ai.azure.com/api/projects/<proj>/connections` | **403** | **200** |
| `<oai>.openai.azure.com/openai/deployments` | **403** | **200** |
| `<oai>.openai.azure.com/openai/deployments/<dep>/chat/completions` | **403** | **200** (推論成功) |
| `<spch>.cognitiveservices.azure.com/speechtotext/v3.1/transcriptions` | **403** | **200** |

VNet 外の 403 のレスポンスボディ:

```json
{"error":{"code":"403","message":"Public access is disabled. Please configure private endpoint."}}
```

> **トークンのオーディエンスに注意。** Foundry のプロジェクト API は
> `https://ai.azure.com` のトークンを要求する。`cognitiveservices.azure.com` や
> `management.azure.com` のトークンを渡すと、ネットワークの判定に到達する前に
> **401** で弾かれる:
>
> ```json
> {"statusCode":401,"message":"Unauthorized. Access token is missing, invalid,
>  audience is incorrect (https://ai.azure.com), or have expired."}
> ```
>
> 401 が出たら「閉域化が効いた」ではなく「トークンが違う」を先に疑うこと。
> 閉域化が効いているときは **403** で、メッセージに `Public access is disabled` が入る。

---

## 3. VM 経由 (同じ VNet) なら操作できるか

> ### ✅ **はい、その認識で合っています。**
>
> VNet 内の probe VM から Foundry のデータプレーン API を叩いて **200** を確認済み。
> Entra ID (マネージド ID) 認証でも 200 で、キー認証に落とす必要もない。

ただし**ブラウザで ai.azure.com を開く場合は、もう 1 つ条件がある。**

### 3.1 見落としやすい前提 — ポータルの Web サイト自体は公開インターネット上にある

`ai.azure.com` は Private Link の対象ではない。Front Door 上の公開 Web サイト。

```
ai.azure.com -> 150.171.110.137   (Azure Front Door の公開 IP)
```

つまり VM 内のブラウザは:

1. **公開インターネット** へ出て `ai.azure.com` の HTML/JS を取得する
2. **Private Endpoint 経由** で `<account>.services.ai.azure.com` のデータプレーンを叩く

の **2 経路を両方**使う。**「完全にインターネットから遮断された VM」では、
ポータルのページ自体が開けない。**

probe VM からの実測 (本構成は VM に Public IP を付けて送信経路を確保している):

| URL | HTTP |
|---|---|
| `https://ai.azure.com` | **200** |
| `https://ml.azure.com` | **200** |
| `https://login.microsoftonline.com` | **200** |
| `https://speech.microsoft.com` | 200 (ページは開くが機能しない → §5) |

### 3.2 VM の送信をファイアウォールで絞る場合に必要なもの

MS Docs が挙げるサービスタグ。Azure Firewall / NSG で egress を絞るならこれらを許可する。

| サービスタグ | 用途 |
|---|---|
| `AzureActiveDirectory` | サインイン |
| `AzureFrontDoor.Frontend` | ポータルの Web サイト配信 |
| `AzureResourceManager` | ARM 呼び出し |
| `CognitiveServicesManagement` | リソース管理 |
| `CognitiveServicesFrontEnd` | ポータルのフロントエンド API |
| `Storage` | **Speech Studio のみ** |

> 出典: [Configure Virtual Networks for Foundry Tools](https://learn.microsoft.com/azure/ai-services/cognitive-services-virtual-networks)
> — "To access and use the Microsoft Foundry portal, LUIS portal, Speech Studio,
> or Language Studio from a virtual network, you need to use the following tags"

---

## 4. デプロイしたモデルは見えるのか — AI Foundry ポータルでどこまでできるか

### 4.1 どこから見るかで変わる

| 見る場所 | 経路 | VNet 外 | VNet 内 |
|---|---|---|---|
| Azure ポータル「モデル デプロイ」 | ARM | ✅ **見える・操作できる** | ✅ |
| `az cognitiveservices account deployment list` | ARM | ✅ 見える | ✅ |
| `terraform state` / `terraform plan` | ARM | ✅ 見える | ✅ |
| AI Foundry ポータルのモデル一覧 | データ面 | ❌ 403 | ✅ 見える |
| AI Foundry ポータルの Playground / Chat | データ面 | ❌ | ✅ 使える |

**「デプロイしたモデルが見えなくなる」ことはない。** Azure ポータルからは常に見える。
AI Foundry ポータルで見たいなら VNet 内から開く。

### 4.2 AI Foundry ポータルで「できること / できないこと」

VNet 内から開いた前提。MS Docs の制限事項と実測の合成。

| 機能 | 閉域化時 | 備考 |
|---|---|---|
| プロジェクト / モデル一覧 | ✅ | データ面。VNet 内なら 200 (実測) |
| Playground / Chat | ✅ | 同上。要モデルデプロイ |
| デプロイの作成 / 削除 | ✅ | 実体は ARM |
| connection の一覧 / 作成 | ✅ | データ面 200 (実測) |
| Code Interpreter / Function Calling | ✅ | Microsoft バックボーン経由 |
| Azure AI Search / File Search をツールとして使用 | ✅ | 対象側にも PE が必要 |
| MCP / OpenAPI / Azure Functions ツール | ✅ | 自 VNet のサブネット経由 |
| Bing Grounding / Websearch / SharePoint | ⚠️ | **動くが公開インターネット経由**。全経路を閉じたい要件には合わない |
| Fabric Data Agent | ❌ | Fabric 側の public 有効が必須 |
| Logic Apps ツール | ❌ | 未対応 |
| Browser Automation / Computer Use / Image Generation | ❌ | 未対応 |
| AI Gateway (APIM) | ⚠️ | Foundry UI から作ると public になる。別途 Azure ポータルで閉域化が必要 |

> 出典: [How to configure network isolation for Microsoft Foundry](https://learn.microsoft.com/azure/ai-foundry/how-to/configure-private-link)
> の "Agent tools with network isolation" / "Limitations and considerations"

### 4.3 「プロジェクト」が 2 種類あり、ポータルは両方を同じ一覧に並べる

ポータルで何を見ているかを取り違えると切り分けが破綻する。

| | v1 (Hub ベース) | v2 (アカウント入れ子) |
|---|---|---|
| ARM 種別 | `Microsoft.MachineLearningServices/workspaces` | `Microsoft.CognitiveServices/accounts/projects` |
| 本構成での名前 | `aifp-aissbx` | `proj-aissbx` |
| Terraform | `azurerm_ai_foundry_project` | `azurerm_cognitive_account_project` |
| ネットワーク制限の支配元 | 自身の `publicNetworkAccess` | **親アカウント**の設定 |

**URL のリソース ID で判別する:**

| URL に含まれる文字列 | 開いているもの |
|---|---|
| `.../Microsoft.CognitiveServices/accounts/...` | **v2** |
| `.../Microsoft.MachineLearningServices/workspaces/...` | **v1** |

本構成の v2 プロジェクトのエンドポイント (`terraform output aiservices_project`):

```
https://ais-aissbx-xxxxx.services.ai.azure.com/api/projects/proj-aissbx
```

> **v2 プロジェクトは自動生成されなかった。** `allowProjectManagement = true` でも
> `associatedProjects` は `null` のままだったため、`azurerm_cognitive_account_project`
> で明示的に作成している。先行検証 `ai/ai_foundry` (public 有効で作成) では
> 自動生成されていたので挙動が違う。原因は切り分けていない **[未確定]**。

---

## 5. Speech Studio だけは VNet 内でも使えない

**これは他と性質が違う。** MS Docs が明示的に非対応と書いている。

> "If you allow only private endpoints through the Networking > Private endpoint
> connections tab, **you can't use Speech Studio** with the Speech resource."
>
> "Access to Speech Studio **through private or VNet service endpoints is not supported**."

| Speech リソースのネットワーク設定 | Speech Studio |
|---|---|
| All networks | 制限なし |
| Selected Networks and Private Endpoints | **許可した公開 IP からのみ** |
| **Disabled (本構成)** | **使用不可** |

VM からページ自体は開ける (HTTP 200) が、リソースに紐づく操作ができない。

### 回避策 (MS Docs 記載)

- 開発用に public な Speech リソースを別途用意し、Studio でカスタムモデルを作って
  `Models_CopyTo` REST で本番リソースへコピーする
- Studio を使わず [Speech to text REST API](https://learn.microsoft.com/azure/ai-services/speech-service/rest-speech-to-text) で完結させる
- カスタム音声は [Custom voice REST API](https://learn.microsoft.com/rest/api/aiservices/speechapi/operation-groups) を直接使う

Speech は閉域化の影響が最も大きい。詳細は [05-speech.md](05-speech.md)。

---

## 6. まとめ

| 質問 | 回答 |
|---|---|
| GUI (ポータル) で操作できる? | **どのポータルかによる。** Azure ポータル (ARM) は VNet 外からもそのまま使える |
| AI Foundry のモデルデプロイは? | **Azure ポータルからなら VNet 外でもできる**。実体は ARM 操作 |
| AI Foundry ポータル (ai.azure.com) は? | VNet 外からは 403。**VNet 内からなら使える** |
| VM 経由 (同じ NW) なら操作できる? | **はい。** 実測で 200。ただし VM が `ai.azure.com` への**インターネット送信**もできる必要がある |
| デプロイしたものは見える? | **Azure ポータルからは常に見える。** AI Foundry ポータルで見るなら VNet 内から |
| Speech Studio は? | **VNet 内でも使えない。** 唯一の例外 |
