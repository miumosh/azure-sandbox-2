# AI サービス閉域化 (Public 無効 + Private Endpoint) 検証

Speech / AI Foundry (AI Services) / Azure OpenAI の 3 アカウントを
**public 無効 + Private Endpoint のみ**で構成し、実際に apply して検証した Terraform 一式。

先行検証の `ai/ai_foundry` は「ポータル優先 = public 有効 + PE 併存」方針だった。
こちらは**逆に振り切って閉じたときに何が壊れるか**を見るためのもの。

**実測日: 2026-09-15 / japaneast / Terraform 1.15.5 / azurerm 4.76.0**
apply 後の `terraform plan` は `No changes` (ドリフトなし)。

---

## ドキュメント

| | 内容 |
|---|---|
| [00-glossary.md](docs/00-glossary.md) | **用語集。** 「AI Foundry」「プロジェクト」「閉域化」が何を指すのか、プレーンの違い、HTTP ステータスの読み方、Terraform リソース早見表 |
| [01-private-dns-zones.md](docs/01-private-dns-zones.md) | **Private DNS Zone — 閉域化の本体。** 必要なゾーン 8 本、PE 1 個 = IP 1 個ではない話、`customDnsConfigs` が空になる話 |
| [02-verification-results.md](docs/02-verification-results.md) | **実測結果の全量。** VNet 内外の到達性、踏んだエラー一覧 |
| [03-portal-and-gui.md](docs/03-portal-and-gui.md) | **GUI (ポータル) は操作できるか。** Azure ポータル / AI Foundry ポータル / Speech Studio の可否、モデルデプロイ、VM 経由の条件 |
| [04-storage-and-keyvault.md](docs/04-storage-and-keyvault.md) | **Storage の閉域化と Key Vault の Secret。** 閉じてよいのか、Secret はどうなるのか |
| [05-speech.md](docs/05-speech.md) | **Speech の閉域化。** 影響が一番大きい。取り消せない変更を含む |
| [06-operations.md](docs/06-operations.md) | 疎通確認 / トラブルシュート / モード切替 / 課金 / destroy |
| [07-managed-network.md](docs/07-managed-network.md) | **`managed_network` とは何か。** 受信 (PE) と送信 (managed VNet) の違い、Storage 閉域化との関係 |
| [08-v1-vs-v2.md](docs/08-v1-vs-v2.md) | **「AI Foundry」が指すもの / v1 (Hub) と v2 の違い / Terraform リソース対応表 / virtual network injection の実測** |

---

## 1. 結論サマリ

| 対象 | 閉域化 | 結論 |
|---|---|---|
| AI サービス API (SDK / REST) | ✅ 問題なし | PE + 正しいゾーンがあれば VNet 内から普通に使える |
| Entra ID (キーレス) 認証 | ✅ 問題なし | PE 経由でトークン認証も 200。閉域化と両立する |
| **Azure ポータル** (`portal.azure.com`) | ✅ **VNet 外でも使える** | ARM (コントロールプレーン) は閉域化の影響を受けない |
| **モデルのデプロイ** | ✅ **VNet 外でもできる** | 実体は ARM 操作。Terraform / Azure ポータルどちらからも |
| **AI Foundry ポータル** (`ai.azure.com`) | ⚠️ **VNet 内からのみ** | VNet 外は 403。踏み台 VM / VPN / ExpressRoute が必要 |
| **Speech SDK** | ⚠️ **コード変更が必要** | `FromSubscription` → `FromEndpoint`。しかも**取り消し不可** |
| **Speech Studio** | ❌ **VNet 内でも不可** | 唯一の例外。MS Docs が明示的に非対応 |
| Hub の Storage 紐づけ | ✅ 閉じてよい / 推奨 | ただし単独で閉じない。`managed_network` + `bypass` とセット |
| Key Vault の Secret | ✅ 影響なし | ネットワークと Secret の有無は**別軸**。閉域化しても残り、使われ続ける |
| Hub / Storage / KV の同時閉域化 | ✅ 可能 | 実測で Hub 作成が 1 分 15 秒で成功。**`managed_network` は作成の条件ではない** (§2) |

### 到達性 (実測)

| | VNet 内 (probe VM) | VNet 外 (実行端末) |
|---|---|---|
| 名前解決 | **PE のプライベート IP** (`10.60.10.x`) | 公開 IP |
| データ面 API | **200** (推論成功) | **403** `Public access is disabled. Please configure private endpoint.` |
| ARM (コントロールプレーン) | 200 | **200** |
| ルートパス `/` | 200 | **200** ← 判定に使えない |

> ### ⚠ 最重要の落とし穴
>
> **ルートパス `/` は public 無効でも 200 を返す。**遮断の判定にまったく使えない。
> 必ず実際のデータ面 API を叩き、`403 "Public access is disabled"` が出るかで判定する。
>
> **公開 IP に解決されること自体も異常ではない。**公開 DNS の CNAME チェーンは
> 意図的に誰からでも引ける設計になっている。

---

## 2. 受信と送信は別の話 — `managed_network` の位置づけ

`public_network_access = Disabled` + PE までは「**受信**」の話。
`managed_network` は「**送信**」の話で、両者は互いの代替にならない。

| | 設定対象 | 何を制御するか | 向き |
|---|---|---|---|
| `public_network_access = "Disabled"` + Private Endpoint | Hub / Storage / Key Vault それぞれ | **誰がそのリソースに入ってこられるか** | **受信** |
| `managed_network { isolation_mode }` | Hub のみ | **Hub の中で動く計算リソースが、どこへ出ていけるか** | **送信** |

### なぜ Hub に「送信」があるのか

Hub は設定の箱ではなく、**実際に計算リソースを動かす** (compute instance /
prompt flow のランタイム / 評価ジョブ / serverless Spark)。
**これらはあなたの VNet ではなく、Microsoft 管理のサブスクリプション内で動く。**

Storage を閉じると「PE のある VNet の中」からしか入れなくなるが、
**Hub の計算リソースはあなたの VNet の中にいない。** この経路を埋めるのが
`managed_network` で、有効にすると Azure が Hub 専用のマネージド VNet を作り、
依存リソースへの**マネージド Private Endpoint を自動で張る**。

本構成で自動作成されたもの (`category: Required` = Azure が必須と判断したもの):

```
Inactive   PrivateEndpoint  Required   staissbxhubxxxxx/blob
Inactive   PrivateEndpoint  Required   staissbxhubxxxxx/file
Inactive   PrivateEndpoint  Required   kv-aissbx-xxxxx/vault
Inactive   PrivateEndpoint  Required   aif-aissbx/amlworkspace
```

### ⚠ 訂正 — Hub の作成に `managed_network` は要らなかった

初版では「`managed_network` + `bypass` をセットにすれば Hub 作成が通る」と書いたが、
**因果を検証していなかった。A/B テストの結果、誤りだった。**

同じ private Storage / private Key Vault に対し
`managedNetwork.isolationMode = "Disabled"` の Hub を作ったところ **成功した**:

```json
{ "mn": "Disabled", "pna": "Disabled", "prov": "Succeeded" }
```

さらに本構成側のマネージド VNet も**実際には構築されていなかった**
(`status` が null、outbound rules は 4 本とも `Inactive`)。
`isolation_mode` を設定しても、マネージド VNet は初回の計算リソース作成時まで
構築されない (**遅延プロビジョニング**)。

**理由:** Hub の作成は ARM (コントロールプレーン) 操作で、Storage のデータ面に触らない。
Key Vault に入る SAS の発行も Storage のコントロールプレーン操作。だから閉じていても作れる。

**`managed_network` が効くのは作成時ではなく実行時** — prompt flow / 評価 / compute が
閉じた Storage の**データ面**を叩くとき。**本検証ではそこまで実行していない [未検証]。**

### 3 層に分けて考える

「Storage の閉域化」を 1 つの話だと思うと混乱する。

| 層 | 設定 | 問い | 検証状況 |
|---|---|---|---|
| **① Storage の受信** | Storage の `public_network_access_enabled = false` + blob/file の PE | 誰が Storage に入れるか | ✅ VNet 外から 403 を確認 |
| **② Hub の受信** | Hub の `public_network_access = "Disabled"` + amlworkspace の PE | 誰が Hub に入れるか | ✅ 作成成功・PE 登録確認 |
| **③ Hub の送信** | Hub の `managed_network { isolation_mode }` | Hub の計算が Storage にどう出ていくか | ⚠️ 宣言のみ・**未プロビジョニング・未検証** |

①と②は独立。**③は①をやったときに初めて問題になり、効くのは実行時。**

| やりたいこと | 必要な設定 |
|---|---|
| 推論エンドポイントだけ使う | **そもそも Hub も Storage も不要。** v2 (`kind = AIServices`) のみで完結 |
| Hub は作るが Storage は開けておく | ①なし / ②あり / ③なし |
| Hub も Storage も閉じる (prompt flow 等は使わない) | ①あり / ②あり / **③は無くても作成は通る** |
| Hub も Storage も閉じて prompt flow / 評価も動かす | ①あり / ②あり / **③あり** + マネージド VNet のプロビジョニングが必要 |

> **`managed_network` は「VNet 統合」ではない。** Microsoft 管理のサブスク内に
> Hub 専用の VNet が作られる方式で、中身は不可視。
> あなたのサブネットにコンテナを注入する Foundry v2 の
> **virtual network injection** とは別物。

詳細は [07-managed-network.md](docs/07-managed-network.md)。

---

## 3. v1 (Hub) と v2 — 「AI Foundry」は 3 つの別物を指す

| 呼び方 | 実体 |
|---|---|
| AI Foundry **ポータル** | `ai.azure.com` という Web サイト (ARM リソースではない) |
| AI Foundry **Hub** (v1) | `Microsoft.MachineLearningServices/workspaces` (kind=Hub) |
| AI Foundry **リソース** (v2) | `Microsoft.CognitiveServices/accounts` (kind=AIServices) |

ポータルは **v1 系と v2 系のプロジェクトを同じ一覧に並べる**ため、
画面が同じでも裏のリソースは別物になりうる。

| | **v1 (Hub)** | **v2 (アカウント)** |
|---|---|---|
| 親 | `azurerm_ai_foundry` | `azurerm_cognitive_account` (`kind = "AIServices"`) |
| プロジェクト | `azurerm_ai_foundry_project` | `azurerm_cognitive_account_project` (入れ子) |
| **Storage / Key Vault** | **必須** | **不要** |
| 受信 PE の subresource | `amlworkspace` | `account` |
| DNS ゾーン | `api.azureml.ms` / `notebooks.azure.net` | `cognitiveservices` / `openai` / `services.ai` |
| **送信の閉域化** | `managed_network` (**Microsoft 管理サブスクの VNet**) | `network_injection` (**あなたの VNet に注入**) |
| 得意なこと | managed compute / prompt flow / 評価 | 推論 / Agent Service / Playground |

> **v1 の Hub は AI Services とは別リソースで、connection を張らないと繋がらない。
> v2 のプロジェクトはアカウントの入れ子なので最初から一体。**
>
> **推論エンドポイントを使うだけなら v1 は不要。** Storage / Key Vault と
> その PE・DNS ゾーンという大きな依存がまるごと消える。

### virtual network injection (v2 の送信側) — 実測

`managed_network` (v1) と `network_injection` (v2) は**どちらも「送信」の話だが方式が逆**。

| | **v1: `managed_network`** | **v2: `network_injection`** |
|---|---|---|
| VNet はどこに | **Microsoft 管理のサブスク内** | **あなたの VNet** |
| 見えるか | ❌ 不可視 | ✅ サブネットとして見える |
| 事前準備 | 不要 | **`Microsoft.App/environments` 委任サブネット** (最小 /27・推奨 /24) |
| 後から追加 | ✅ 可能 | ❌ **作成時のみ。再作成が必要** |
| 作成時間 (実測) | Hub 1 分 15 秒 | アカウント **5 分 35 秒** |

実際にデプロイして確認した ARM プロパティ:

```json
"networkInjections": [{
  "scenario": "agent",
  "subnetArmId": ".../virtualNetworks/vnet-aissbx/subnets/snet-agent",
  "useMicrosoftManagedNetwork": false      // ← ここが v1 との分岐点そのもの
}]
```

**あなたのサブネットに実体ができる** (v1 では何も作られない):

```
snet-agent  10.60.40.0/24  delegation: Microsoft.App/environments
            serviceAssociationLinks: legionservicelink → Microsoft.App/environments
```

`enable_vnet_injection = true` (既定) で検証用アカウント `aisinj-*` が作られる。
Agent の実行までは検証していない (BYO の Storage/Cosmos/AI Search が別途必要) **[未検証]**。

詳細は [08-v1-vs-v2.md](docs/08-v1-vs-v2.md)。

---

## 4. 構成

```
ai/ais/
├── providers.tf              # terraform ~> 1.15.5 / azurerm ~> 4.76.0
├── locals.tf                 # 構成値の集中管理 (DNS ゾーン定義もここ)
├── variables.tf              # 機微 / 環境依存値 / 検証スイッチ
├── network.tf                # RG / VNet / サブネット
├── dns.tf                    # Private DNS Zone + VNet リンク (一元管理)
├── main.tf                   # AI サービス 3 アカウント / v2 プロジェクト / モデルデプロイ
├── hub.tf                    # AI Foundry Hub (v1) + Storage + Key Vault
├── jumpbox.tf                # 検証用 Linux VM / Bastion + Windows VM / RBAC
├── outputs.tf
├── verify.sh                 # 閉域経路の疎通確認 (az vm run-command)
├── terraform.tfvars.sample   # cp して terraform.tfvars を作る
├── .gitignore                # tfvars / tfstate / 秘密鍵 / .terraform を除外
├── docs/                     # 調査結果の詳細
└── modules/
    └── cognitive_account/    # kind 切替可能な Cognitive アカウント + PE
```

### 作るもの

| 種別 | 内容 |
|---|---|
| Cognitive アカウント | Speech (`SpeechServices`) / AI Services (`AIServices`) / OpenAI (`OpenAI`) — **3 つとも public 無効**。+ injection 検証用 (`aisinj-*`) |
| Private Endpoint | 上記 4 つ + Hub + Storage (blob/file) + Key Vault = **7 個** |
| Private DNS Zone | **8 本** + VNet リンク ([01](docs/01-private-dns-zones.md)) |
| AI Foundry | **v1** Hub + v1 Project / **v2** アカウント + プロジェクト (両方作って対比できる) |
| モデルデプロイ | `gpt-5.4-mini` を AIServices / OpenAI の両方に |
| 検証用 | Linux probe VM (マネージド ID + RBAC 付き)、任意で Bastion + Windows VM |

Private DNS Zone は**ルートの `dns.tf` で一元的に作り**、各 PE には ID だけを配る。
`ai/ai_foundry` の「1 つ目のモジュールが作って 2 つ目が再利用」方式より素直
(理由は [01-private-dns-zones.md](docs/01-private-dns-zones.md) §8)。

### 機微情報の扱い

構成値は `locals.tf`、機微 / 環境依存値と検証スイッチは `variables.tf` (tfvars) に分離。
`terraform.tfvars` はリポジトリルートと `ai/ais/.gitignore` の**両方**で除外し、
`*.sample` のみ追跡する。state には Storage の SAS / Cognitive のアクセスキー /
SSH 秘密鍵が平文で載るため、`*.tfstate` と `generated/` も同様に除外している。

---

## 5. 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id を埋める
terraform init
terraform plan
terraform apply
./verify.sh                                   # VNet 内 / 外の両方から疎通確認
```

`verify.sh` の出力例:

```
== VNet 内 (probe VM) からの結果 ==============================
--- nslookup (PE のプライベート IP に解決されるか) ---
  aiservices  ais-aissbx-xxxxx.services.ai.azure.com         OK   private
  openai      oai-aissbx-xxxxx.openai.azure.com              OK   private
  speech      spch-aissbx-xxxxx.cognitiveservices.azure.com  OK   private

--- データ面 API (Entra ID 認証 / 403=遮断 200=疎通) ---
  openai      chat/completions (gpt-5-4-mini)                HTTP 200
  speech      speechtotext/v3.1/transcriptions               HTTP 200

== 実行端末 (VNet 外) からの結果 ===============================
  -- データ面 API (VNet 外)。403 "Public access is disabled" が閉域化の証拠 --
  openai      HTTP 403   Public access is disabled. Please configure private endpoint
  speech      HTTP 403   Public access is disabled. Please configure private endpoint
```

### 主な検証スイッチ (`terraform.tfvars`)

| 変数 | 既定 | 内容 |
|---|---|---|
| `ai_network_mode` | `"private"` | `private` / `portal` / `restricted` の 3 モード ([06](docs/06-operations.md) §4) |
| `enable_foundry_hub` | `true` | v1 Hub + Storage + Key Vault を作るか |
| `hub_dependencies_private` | `true` | Storage / Key Vault も閉じるか |
| `enable_jumpbox` | `true` | 検証用 Linux VM。**閉域の検証には実質必須** |
| `enable_bastion` | `false` | ポータル手動確認用の Bastion + Windows VM。**時間課金** |
| `enable_vnet_injection` | `true` | v2 の virtual network injection 検証用アカウントを作るか (§3) |
| `enable_model_deployment` | `true` | `gpt-5.4-mini` をデプロイするか |

---

## 6. なぜ VNet 内からしか検証できないのか

閉域化した AI サービスは、実行端末からの `nslookup` / `curl` では**何も判定できない**。
公開 DNS の応答しか見えないため、VNet 内に観測点が要る。

本構成は Linux probe VM を置き、`az vm run-command` 越しにコマンドを流す。
**SSH も Bastion も不要**で、認証は VM のマネージド ID (Entra ID) を使うため
キーをスクリプトに埋め込まずに済む。

ブラウザでポータルを触る場合だけ Bastion + Windows VM が要る
(`enable_bastion = true`、手順は [03-portal-and-gui.md](docs/03-portal-and-gui.md))。

---

## 7. 出典

- [Azure Private Endpoint private DNS zone values](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)
- [Configure Virtual Networks for Foundry Tools](https://learn.microsoft.com/azure/ai-services/cognitive-services-virtual-networks)
- [How to use private endpoints with Speech service](https://learn.microsoft.com/azure/ai-services/speech-service/speech-services-private-link)
- [How to configure network isolation for Microsoft Foundry](https://learn.microsoft.com/azure/ai-foundry/how-to/configure-private-link)
- [Set up an Azure Key Vault Connection](https://learn.microsoft.com/azure/ai-foundry/how-to/set-up-key-vault-connection)
- 先行検証: `ai/ai_foundry/README.md` (public 有効 + PE 併存の実測記録とハマりどころ)
