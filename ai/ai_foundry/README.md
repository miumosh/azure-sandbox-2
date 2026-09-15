# AI Foundry サンドボックス

AI Foundry (Hub / Project) + AI Services + Storage を Private Endpoint 前提で構成する Terraform 一式。
`images/` にある既存コードのスクリーンショットを元に再構成したもの。

このドキュメントは**実際に apply して踏んだ問題と、その原因・対処**を残すことを主目的にしている。
Azure 側が後からリソースを書き換える箇所が複数あり、素直に書くと壊れる。

---

## 1. 構成

### リソース

| モジュール | 作成するもの |
|---|---|
| `modules/ai_foundry` | `azurerm_ai_foundry` (Hub) / `azurerm_ai_foundry_project` / `azurerm_cognitive_account` (kind=AIServices) / Private DNS Zone + VNet リンク / Private Endpoint |
| `modules/storage` | `azurerm_storage_account` / Blob コンテナ / 静的 Web サイト (任意) / Private DNS Zone + VNet リンク / Private Endpoint (blob/file/queue/table/web/dfs) |
| ルート | Resource Group / VNet + サブネット / Key Vault / 上記モジュール呼び出し |

Hub が必須とする Storage Account と Key Vault はルートで作成してモジュールへ ID を渡す。

### ディレクトリ

```
ai/ai_foundry/
├── main.tf                    # 共通基盤 + module 呼び出し
├── locals.tf                  # 構成値の集中管理 (object map)
├── variables.tf               # 機微 / 環境依存値のみ
├── outputs.tf
├── providers.tf               # terraform ~> 1.15.5 / azurerm ~> 4.76.0
├── terraform.tfvars.sample    # cp して terraform.tfvars を作る
├── images/                    # 元コードのスクリーンショット
└── modules/
    ├── ai_foundry/{main,variables,outputs}.tf
    └── storage/{main,variables,outputs}.tf
```

構成値は `locals.tf`、機微 / 環境依存値は `variables.tf` (tfvars) に置く。
`terraform.tfvars` はリポジトリルートの `.gitignore` で除外され、`*.sample` のみ追跡する。

### 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id 等を埋める
terraform init
terraform plan
terraform apply
```

---

## 2. ネットワーク設計方針

### 公開範囲

| リソース | 公開範囲 | 根拠 |
|---|---|---|
| AI Foundry Hub / Project | **Public** | 触るのは人間 (開発者)。Entra ID + RBAC で守る。本番のデータパスには載らない |
| AI Services | **Public + PE 併存** (既定) | 本来は PE 専用にしたいが、ポータルが使えなくなるため既定は開ける。§4.4 参照 |
| Storage / Key Vault | **Public** | Hub が Public である以上、Studio のファイルブラウザ動線 (ブラウザ→Storage データ面) も Public 前提 |

想定する利用形態は **AKS 等 VNet 内のワークロード → Private Endpoint → AI Services**。
AKS からの推論リクエストは Hub を経由せず AI Services のエンドポイントを直接叩くため、
**Hub が Public でも本番トラフィックの機密性には影響しない**。これがこの構成の根拠。

Storage を Public にしているのは中途半端な妥協ではなく、Hub を Public にする方針と揃えた結果。
ここだけ閉じると「Hub は Public なのに Studio でデータセットが見えない」という歪んだ状態になる。

### 閉域化を進める場合の段階

| 段階 | 閉じる範囲 | 追加で必要なもの |
|---|---|---|
| **A (現状)** | AI Services のみ (モード次第) | なし |
| **B** | + Storage / Key Vault | Hub の `managed_network` (managed VNet)、Key Vault の PE + `privatelink.vaultcore.azure.net`、コンテナ作成の azapi 化 |
| **C** | + Hub 自体 | 上記 + Hub PE (subresource `amlworkspace`) + `privatelink.api.azureml.ms` / `privatelink.notebooks.azure.net` + 踏み台 VM / VPN + DNS フォワーダ |

**注意: 「Storage だけ閉じる」が一番壊れやすい。** Hub は Storage / Key Vault を実際に使う
(データセット、prompt flow のファイル、評価結果)。到達経路を用意せずに Storage だけ閉じると
プロジェクト作成や prompt flow が失敗する。閉じるなら以下のどちらかとセットで行うこと。

- Hub の `managed_network` を有効化 (`managed_network_isolation_mode` 変数を用意済み)
- Storage 側で `network_rules` の `bypass = ["AzureServices"]` + リソースインスタンスルール

B の「完全閉域 Storage に terraform からコンテナを作れない」問題は、このリポジトリに前例がある:
`test/storage-adf-psql-function-aks-relation/terraform/envs/spoke-subscription/main.tf` の
`azapi_resource "deployments"` (ARM コントロールプレーン経由でデータ面依存を断つ)。

### Private DNS Zone

AI Services の PE は 1 個 (subresource = `account`) だが、**その NIC のプライベート IP に対して
クライアントが引くホスト名ごとのゾーンに A レコードが必要**。

| 呼び出す SDK | ホスト名 | 必要なゾーン |
|---|---|---|
| Speech / Vision / Language / Content Safety | `<sub>.cognitiveservices.azure.com` | `privatelink.cognitiveservices.azure.com` |
| Azure OpenAI SDK (GPT / embeddings) | `<sub>.openai.azure.com` | `privatelink.openai.azure.com` |
| Azure AI Inference SDK | `<sub>.services.ai.azure.com` | `privatelink.services.ai.azure.com` |

**現在は cognitiveservices の 1 本のみ**。用途が従来の Cognitive Services 系であり、
元コードも AOAI を別アカウント / 別モジュール (`module "aoai_eastus2"` 等) に分離していたため。
このアカウントに OpenAI モデルをデプロイするなら `privatelink.openai.azure.com` の追加が必要
(`locals.tf` の `ai_services_private_dns_zone_names`)。**ゾーンが足りないと名前解決できず、
public 無効時は到達不可になる**。

PE の `customDnsConfigs` を見ると、ゾーン未登録のホスト名も確認できる:

```bash
az network private-endpoint show -g aifsbx-rg -n pep-ais-<suffix> --query customDnsConfigs
```

AI Services を呼ぶワークロード (AKS 等) を**別 VNet** に置く場合は、peering に加えて
その VNet も `local.private_dns_zone_vnet_links` に追加しないと PE に名前解決できない。

同一 RG 内で同名の Private DNS Zone は 1 つしか作れないため、2 つ目以降の Storage は
`create_private_dns_zone = false` + `private_dns_zone_ids` で 1 つ目のゾーンを再利用する
(`module.storage_data` が実例)。

---

## 3. AI Services のネットワークモード

`var.ai_services_network_mode` で切り替える。**実測に基づく 3 モード**。

| モード | 設定 | ポータル | API (許可 IP から) | PE 経由 (AKS) |
|---|---|---|---|---|
| `portal` (既定) | public 有効 + `default_action = Allow` | **使える** | 可 | 可 |
| `restricted` | public 有効 + `Deny` + `allowed_client_ips` | **使えない** | 可 | 可 |
| `private` | public 無効 | VNet 内のみ | 不可 | 可 |

**どのモードでも PE 経由の経路は維持される**ため、AKS からの利用は常に可能。
public 無効と `default_action` の優先関係は[`public_network_access_enabled` と `network_acls` の関係](#public_network_access_enabled-と-network_acls-の関係-評価順序)を参照。

### 両立構成の勘所 — ポータルを使いつつ AKS から Private に叩く

**結論: `portal` モード (public 有効 + `default_action = Allow`) に PE を併存させる。**
「public を有効化したうえで Private Endpoint も作り、公開/私設の両経路を用意する」という理解で正しい。
これが既定の構成であり、`main.tf` は `create_private_endpoint = true` を常に渡している。

ただし **PE を作っただけでは AKS からの通信は Private にならない**。
本当の決め手は Private DNS Zone の方にある (下表 #6 / #7)。

#### 必須パラメータ

`module.ai_foundry` の変数と、それが最終的にどの Terraform リソースのどの引数になるかを併記する
(実リソースはすべて `modules/ai_foundry/main.tf` 内)。

| # | モジュール変数 | 定義場所 | 実リソース | 実引数 | 値 | 役割 | 外すと |
|---|---|---|---|---|---|---|---|
| 1 | `ai_services_public_network_access_enabled` | `locals.tf` (`var.ai_services_network_mode != "private"` から導出) | `azurerm_cognitive_account.ai_services` | `public_network_access_enabled` (ARM: `properties.publicNetworkAccess`) | `true` | 公開エンドポイントを開く。**ポータルの前提** | ポータルが VNet 内からしか使えない |
| 2 | `ai_services_network_acls.default_action` | `locals.tf` (`ai_services_network_mode = "portal"`) | `azurerm_cognitive_account.ai_services` | `network_acls { default_action }` (`dynamic` ブロック) | `Allow` | **ポータルの前提** (§4.4 で実測) | `Deny` だと許可 IP を入れてもポータル警告が消えない |
| 3 | `ai_services_custom_subdomain_name` | モジュール内で自動 (`local.ai_services_subdomain`) | `azurerm_cognitive_account.ai_services` | `custom_subdomain_name` | AI Services 名 | **PE / Entra ID 認証 / `network_acls` すべての必須条件** | PE を作っても名前解決できない。後から足すと `ForceNew` で再作成 |
| 4 | `create_private_endpoint` | `main.tf` (`module "ai_foundry"`) | `azurerm_private_endpoint.ai_services` | `count = local.private_endpoint_count` | `true` | AKS 向けの私設 IP を用意する | 私設経路そのものが無い |
| 5 | `private_endpoint_subnet_id` | `main.tf` (`azurerm_subnet.this["pe"].id`) | `azurerm_private_endpoint.ai_services` | `subnet_id` | PE 用サブネット | PE の NIC 配置先 | — (`create_private_endpoint = true` なら必須) |
| 6 | **`private_dns_zone_names`** | `locals.tf` (`ai_foundries.main.ai_services_private_dns_zone_names`) | `azurerm_private_dns_zone.ai_services` (`for_each = local.managed_dns_zone_names`) | `name` → `azurerm_private_endpoint.ai_services` の `private_dns_zone_group { private_dns_zone_ids }` | **呼ぶ SDK のホスト名に対応するゾーンを全部** | ★**実質ここが Private 化の本体** | **ゾーン不足 = 公開 IP に解決してインターネット経由になる。エラーが出ないので気づけない** |
| 7 | **`private_dns_zone_virtual_network_ids`** | `locals.tf` (`private_dns_zone_vnet_links`) | `azurerm_private_dns_zone_virtual_network_link.ai_services` (`for_each = local.dns_zone_links`) | `virtual_network_id` | **AKS の VNet を含める** | ゾーンを VNet にリンクする | リンク漏れ = 同上 (その VNet からは公開 IP に解決される) |
| 8 | `ai_services_local_auth_enabled` | `locals.tf` (`ai_foundries.main`) | `azurerm_cognitive_account.ai_services` | `local_auth_enabled` | **`false` 推奨** (現状 `true`) | public 全開放の代償を Entra ID + RBAC で埋める | API キーが漏れるとインターネットから直接叩ける |

`azurerm_private_endpoint.ai_services` の `private_service_connection { subresource_names = ["account"] }`
はモジュール内で固定。AI Services (kind = `AIServices`) の PE はこの 1 種類のみで、
**ホスト名ごとに PE を増やすのではなく #6 のゾーンを増やす**のが正しい対処になる。

#### この構成が実際に守っているもの / 守っていないもの

`default_action = Allow` である以上、**ネットワーク層の制限は実質かかっていない**。
正確に把握しておくべき実像は次のとおり。

| 経路 | 実態 |
|---|---|
| インターネット → 公開エンドポイント | **開いている**。守っているのは**認証 (Entra ID / API キー) と RBAC だけ** |
| AKS → PE | **DNS がそう解決した場合にのみ** Private。強制はされない |

つまり **PE は「Private にする装置」ではなく「Private な宛先を用意する装置」**。
実際に Private を通るかどうかはクライアント側の名前解決に委ねられている。
だから #6 / #7 が最重要であり、#8 (`local_auth_enabled = false`) が
「公開エンドポイントが開いている」ことへの実質的な補償になる。

#### 現状のコードで足りていない点 (AKS を足すときに必ず踏む)

| 項目 (モジュール変数) | 実リソース / 実引数 | 現状 | AKS 利用時にやること |
|---|---|---|---|
| `ai_services_private_dns_zone_names` | `azurerm_private_dns_zone.ai_services` の `name` | `privatelink.cognitiveservices.azure.com` の **1 本のみ** | AOAI を使うなら `privatelink.openai.azure.com`、Azure AI Inference SDK なら `privatelink.services.ai.azure.com` を**追加**（§2「Private DNS Zone」の対応表を参照） |
| `private_dns_zone_vnet_links` | `azurerm_private_dns_zone_virtual_network_link.ai_services` の `virtual_network_id` | `main = azurerm_virtual_network.this.id` の **1 VNet のみ** | AKS が別 VNet なら **peering + このマップへの追加**の両方。peering だけでは名前解決されない |
| `ai_services_local_auth_enabled` | `azurerm_cognitive_account.ai_services` の `local_auth_enabled` | `true` | `false` にして Entra ID 認証のみにする。AKS 側は Workload Identity + `Cognitive Services User` ロール |
| AKS サブネット | (このリポジトリに該当リソースなし) | 未定義 | PE と同一 VNet に置くのが最も単純。別 VNet なら上記 2 つが必須 |

#### 疎通確認

PE が効いているかは**必ず AKS の Pod から**確認する (実行端末からでは意味がない)。

```bash
# Pod 内から。10.50.10.x (PE のプライベート IP) に解決されれば Private 経路
nslookup <subdomain>.cognitiveservices.azure.com

# 公開 IP が返る場合はゾーン不足か VNet リンク漏れ。
# PE が実際に必要としているホスト名の一覧はこれで分かる
az network private-endpoint show -g aifsbx-rg -n pep-ais-<suffix> --query customDnsConfigs
```

#### 「ポータルも使いたい」を捨てられる場合

公開エンドポイントを開けたままにするのが許容できないなら、**両立は諦める**しかない。
`restricted` / `private` のトレードオフは §3 冒頭のモード表と §4.4 のとおり。

| 優先するもの | モード | 代償 |
|---|---|---|
| ポータルの利便性 | `portal` (本節) | 公開エンドポイントが開く。認証と RBAC だけが防御 |
| ネットワーク制限 | `restricted` | ポータルが使えない。API は許可 IP から可 |
| 完全閉域 | `private` | ポータルは踏み台 VM / VPN 経由でのみ |

### `network_acls` の既定値 (`azurerm_cognitive_account`)

> **どの `default_action` の話かを最初に固定する。**
> このリポジトリには `default_action` が **2 か所** ある。名前も取りうる値 (`Allow` / `Deny`) も
> 同じだが、**リソースもプロバイダの実装も既定値も違う**。
>
> | | AI Services (本節) | Storage |
> |---|---|---|
> | リソース | `azurerm_cognitive_account` | `azurerm_storage_account` |
> | ブロック名 | **`network_acls`** | **`network_rules`** |
> | ARM プロパティ | `properties.networkAcls` | `properties.networkAcls` (RP は `Microsoft.Storage`) |
> | このリポジトリの変数 | `var.ai_services_network_acls` (`modules/ai_foundry`) | `var.network_rules` (`modules/storage`) |
>
> 以下は **AI Services (`network_acls`) 側**の話。Storage との差分は末尾の対比表にまとめる。

#### ブロック自体を省略した場合

`network_acls` は **Optional / `MaxItems = 1` / 既定値なし**。
`private` モード (`var.ai_services_network_mode = "private"`) では変数が `null` になり、
`dynamic` ブロックが 0 個になる = **ブロックそのものが存在しない** 状態になる。

このとき何が起きるかは Terraform 層と Azure 層で分けて理解する必要がある。

| 層 | 挙動 | 根拠 |
|---|---|---|
| Terraform (azurerm 4.76.0) | `expandCognitiveAccountNetworkAcls` が `nil` を返し、**`properties.networkAcls` を PUT 本文に一切含めない** | `internal/services/cognitive/cognitive_account_resource.go` L830-835 |
| Azure (ARM) | `networkAcls` 未指定 = **どのネットワークからの接続も受け付ける (実効 `Allow`)** | MS Docs「By default, Foundry Tools resources accept connections from clients on any network.」 |

つまり **「ブロックを書かない」は「Deny」ではなく「Allow 相当」**。
`private` モードで実際に閉じているのは `network_acls` ではなく
`public_network_access_enabled = false` の方であり、ACL は無関係。

> **これは Storage と挙動が違う。** Storage の `network_rules` は、ブロックを省略すると
> プロバイダが `defaultAction = Allow` / `bypass = AzureServices` / 各リスト空、を**明示的に送信**する
> (`expandAccountNetworkRules` L14-24 の `// Default access is enabled when no network rules are set.`)。
> AI Services は**送らない**。結果としてどちらも実効 Allow だが、**API に送る内容が違う**ため
> 差分・ドリフトの出方が異なる (後述)。

#### `public_network_access_enabled` と `network_acls` の関係 (評価順序)

**この 2 つは対等ではなく、上下 2 層のゲート**である。

| 層 | Terraform | ARM プロパティ | 役割 |
|---|---|---|---|
| **上位** | `public_network_access_enabled` | `properties.publicNetworkAccess` | パブリックエンドポイント**そのもの**を開くか閉じるか。Swagger の定義も "Whether or not public **endpoint access** is allowed for this **account**." |
| **下位** | `network_acls` | `properties.networkAcls` | **開いているパブリックエンドポイント**に届いた通信を IP / VNet で絞る。Swagger は "rules governing the accessibility from specific network **locations**" |

したがって **`public_network_access_enabled = false` にした時点で、`default_action = Allow` は
公開経路の判定に効かない**。下位のゲートは、上位が閉じていれば評価する対象そのものが無い。
ポータルの Networking ブレードでも「Allow access from」は
`All networks` / `Selected networks and private endpoints` / `Disabled` の **3 択排他**で、
`Disabled` は `defaultAction` とは別軸の選択肢として並んでいる。

**組み合わせと AI Foundry ポータルの可否:**

| `public_network_access_enabled` | `network_acls.default_action` | 公開エンドポイント | AI Foundry ポータル | 対応モード |
|---|---|---|---|---|
| `true` | `Allow` (またはブロック省略) | 全開放 | **使える** | `portal` |
| `true` | `Deny` + 許可 IP | 許可 IP のみ | **使えない** (§4.4 で実測) | `restricted` |
| `false` | ブロック省略 | 閉塞 (PE のみ) | VNet 内からのみ | `private` |
| `false` | `Allow` を明示 | **閉塞のまま** | **使えない** | (現行モジュールでは生成不可) |

最終行が本節の要点。**`default_action = Allow` は上位ゲートを上書きしない。**
なお `locals.tf` は `private` モードで `ai_services_network_acls = null` にするため、
**この組み合わせ自体が現行コードでは作れない**。試すにはコード変更が必要。

**ポータル警告文の読み方。** §4.4 で観測された

> この Foundry プロジェクトでは、パブリック ネットワーク アクセスが無効になっています。

は文面上 `publicNetworkAccess = Disabled` を指すが、**実際には `Enabled` + `defaultAction = Deny`
でも出た**。つまりポータルは 2 つのゲートを個別に判定しておらず、
**「何らかのネットワーク制限がかかっているか」を静的に見ている**(§4.4 の推論と整合)。

⇒ **警告が出ない条件は AND**: `publicNetworkAccess = Enabled` **かつ** `defaultAction = Allow`。
どちらか一方でも制限側に倒れると警告になる。

**`bypass` だけは別扱い。** MS Docs 上、ポータルの Exceptions (`bypass`) は
`Disabled` を選んでいる時にも表示される。つまり `bypass = AzureServices` は
public 無効でも信頼済み Azure サービス経路には効きうる。
ただし**ブラウザは信頼済みサービスではない**ため、ポータル救済にはならない。**[未検証]**

#### 各パラメータの既定値

ブロックを**書いた場合**の各パラメータ。「provider 既定」は azurerm のスキーマ定義、
「本モジュール既定」は `var.ai_services_network_acls` の `optional(...)` 既定値。

| パラメータ | 型 | Terraform 必須性 | provider 既定 | 本モジュール既定 | 未指定時に ARM へ送る値 |
|---|---|---|---|---|---|
| `default_action` | `string` | **Required** (省略不可) | **なし** | **`"Deny"`** | — (必ず送る) |
| `bypass` | `string` | Optional | なし | `null` (未指定) | **送信しない** (プロパティごと省略) |
| `ip_rules` | `set(string)` | Optional | なし | `[]` | **空配列 `[]`** |
| `virtual_network_rules` | block (set) | Optional | なし | `[]` | **空配列 `[]`** |
| `virtual_network_rules.subnet_id` | `string` | Required | — | — | — |
| `virtual_network_rules.ignore_missing_vnet_service_endpoint` | `bool` | Optional | **`false`** | (未公開) | `false` |

**最大の罠は `default_action`。**
ARM の実効既定は `Allow` なのに対し、**`default_action` は provider 側で `Required`**
(= 既定値がなく、書かないと `terraform validate` で落ちる)。
さらに本モジュールの変数は `optional(string, "Deny")` としているため、
**「ブロックを足したが `default_action` を書かなかった」= `Deny`** となり、
ブロックを足す前後で挙動が **Allow → Deny に反転**する。ブロックを追加する時は必ず明示すること。

#### 値と制約

| パラメータ | 取りうる値 | 制約 |
|---|---|---|
| `default_action` | `Allow` / `Deny` | `ipRules` / `virtualNetworkRules` のどれにも一致しなかった場合の動作。**`bypass` 評価後**に適用される |
| `bypass` | `AzureServices` / `None` | `kind` が `OpenAI` / `AIServices` / `TextAnalytics` **以外**だと plan 時にエラー。本構成は `AIServices` なので可 |
| `ip_rules` | IPv4 アドレス or CIDR (RFC 4632) | ARM 仕様・provider 検証ともに **IPv4 のみ**。**`/31`・`/32` は非対応**なので裸 IP で書く。予約外のパブリック IP のみ (NAT 後の送信元) |
| `virtual_network_rules.subnet_id` | サブネット ID | サブネット側に `Microsoft.CognitiveServices` のサービスエンドポイントが必要 (無い場合は `ignore_missing_vnet_service_endpoint = true` で無視できるが、実際には通らない) |

`bypass` は Storage と違い **`list` ではなく単一 `string`**。`Logging` / `Metrics` は存在しない。

#### ブロック全体の前提条件

```hcl
"network_acls": {
  RequiredWith: []string{"custom_subdomain_name"},
}
```

**`custom_subdomain_name` を設定していないと `network_acls` は使えない** (plan 時エラー)。
本モジュールは `local.ai_services_subdomain` で必ず埋めるため問題にならないが、
`custom_subdomain_name` は `ForceNew` なので後から足すとアカウントごと再作成になる。

#### Storage (`network_rules`) との対比

| 観点 | AI Services `network_acls` | Storage `network_rules` |
|---|---|---|
| ブロックの Terraform 属性 | `Optional` | `Optional` + **`Computed`** |
| 子要素 (`ip_rules` 等) | `Optional` のみ | `Optional` + **`Computed`** |
| ブロック省略時に API へ送る値 | **何も送らない** (`networkAcls` 自体を省略) | `defaultAction = Allow` / `bypass = AzureServices` / 各リスト空 を**明示送信** |
| 実効的な既定の公開範囲 | 全ネットワーク許可 (Docs) | 全ネットワーク許可 |
| Swagger 上の `defaultAction` | `default:` 宣言**なし**・`required` でもない | **`"default": "Allow"`** かつ `required` |
| `bypass` の型 | 単一 `string` (`AzureServices` / `None`) | `set(string)` (`Logging` / `Metrics` / `AzureServices` / `None` の組み合わせ) |
| `bypass` の既定 | なし (未指定なら送信しない) | Swagger 上 `AzureServices` / 本モジュール変数は `["AzureServices"]` |
| 既定値が返ってきた時の state 書き戻し | **無条件に state へ書き戻す** (`flattenCognitiveAccountNetworkAcls`) | **既定値と一致すれば state に書かない** (`// ignore the default values`) |
| 本モジュール変数の `default_action` 既定 | `"Deny"` | `"Deny"` |

最終行のとおり、**このリポジトリの変数既定はどちらも `Deny`** で揃えてある
(= 「ブロックを書くなら閉じる意思がある」という前提)。Azure / provider の既定 (`Allow`) とは逆なので、
変数のドキュメントだけ読んで「既定は Deny」と覚えると ARM の挙動を読み違える。

#### 未検証 / 不確定 (要フラグ)

以下は provider のソースと Docs から**読み取れる範囲**であり、このリポジトリでは実測していない。
`private` モードや ACL の削除を実運用に載せる前に確認すること。

| # | 論点 | 現状の推定 | 確認方法 |
|---|---|---|---|
| 1 | `networkAcls` を送らずに作成したアカウントの GET が `networkAcls` を**返すか** | 返る場合、`network_acls` は `Computed` ではないため Read が state に書き戻し、**`private` モードで差分が出続ける**可能性がある (Storage のような「既定値なら無視」処理が無い) | `az cognitiveservices account show ... --query properties.networkAcls` → その後 `terraform plan` が `No changes` か |
| 2 | 既存の ACL を**消す**目的でブロックを削除した場合 | Update は PATCH (`AccountsUpdateThenPoll`) で、`NetworkAcls` は `json:"networkAcls,omitempty"`。`nil` だと**送信されない** = **Azure 側の設定は消えない**と読める。結果として plan が収束しない恐れ | ブロック削除 → `apply` → `az ... --query properties.networkAcls` が残っているか |
| 3 | `bypass` 未指定時の ARM 実効値 | `None` 相当と推定。Swagger にも Docs にも既定の明記なし | 作成後の GET に `bypass` が現れるか |
| 4 | `public_network_access_enabled = false` 時に `networkAcls` が評価されるか | Swagger の定義上 `publicNetworkAccess` が**上位ゲート**であり、`Disabled` なら `defaultAction` は公開経路の判定に効かないと読める (評価順序の節を参照)。ただし **`private` モードのポータル挙動はこのリポジトリでは未実測** (§4.4 の実測は `restricted` のみ) | `private` で apply → ポータルの Networking が `Disabled` 表示か / VNet 外のブラウザで警告が出るか |
| 5 | public 無効 + `bypass = AzureServices` で信頼済み Azure サービス経路が生きるか | MS Docs 上 Exceptions は `Disabled` 選択時も表示されるため効くと読めるが、ブラウザは対象外なのでポータルは救われない | public 無効 + `bypass` 指定で Azure ML / Search 等からの疎通確認 |

**根拠に使った一次情報**

- provider: `hashicorp/terraform-provider-azurerm` v4.76.0
  - `internal/services/cognitive/cognitive_account_resource.go` (スキーマ L211-270 / `expandCognitiveAccountNetworkAcls` L830 / `flattenCognitiveAccountNetworkAcls` L949 / `bypass` の kind 制約 L393)
  - `internal/services/storage/storage_account_helpers_network.go` (`expandAccountNetworkRules` L14 / `flattenAccountNetworkRules` L36)
- ARM Swagger: `Azure/azure-rest-api-specs`
  - `Microsoft.CognitiveServices/stable/2025-06-01/cognitiveservices.json` → `NetworkRuleSet` / `AccountProperties.publicNetworkAccess`
  - `Microsoft.Storage/stable/2024-01-01/storage.json` → `NetworkRuleSet`
- MS Docs: 「Configure Virtual Networks」 (`ai-services/cognitive-services-virtual-networks.md`)
  - "Change the default network access rule" 節 → 既定は全ネットワーク許可
  - "Grant access to trusted Azure services" 節 → Exceptions (`bypass`) は
    `Selected networks and private endpoints` / `Disabled` のどちらでも表示される

---

## 4. ハマりどころ (重要)

apply 時に実際に踏んだもの。いずれも共通して
**「Azure 側が後からリソースを書き換える領域を Terraform が奪い合う」**パターン。

健全性の判定基準はシンプルで、**apply 後に `terraform plan` が `No changes` になること**。
ここが clean にならない構成は、いずれドリフトや意図しない置換を起こす。

### 4.1 ロール割り当てが 409 になる

```
Error: unexpected status 409 ... RoleAssignmentExists:
The role assignment already exists. The ID ... is <ROLE_ASSIGNMENT_ID>.
```

**原因**: AI Foundry (Azure ML workspace) は作成時に**自分の MSI へロールを自動付与する**。
Terraform で同じ割り当てを宣言すると重複して 409 になる。

実際に自動付与されていたもの (apply 後に確認):

| プリンシパル | ロール | スコープ |
|---|---|---|
| Hub MSI | Storage Blob Data Contributor / Storage File Data Privileged Contributor | Hub 用 Storage |
| Hub MSI | Key Vault Administrator | Key Vault |
| Project MSI | 上記 + Storage Account Contributor / Reader / Azure AI Administrator | 各スコープ |

**対処**: Terraform 側では宣言しない。追加権限 (例: 利用者への Cognitive Services User) が
必要になった場合のみ明示的に足す。

### 4.2 Storage の CORS で差分が出続ける

**原因**: AI Foundry は Hub に紐付けた Storage へ **Studio 用の CORS ルールを自動設定**する。

```
origins: https://mlworkspace.azure.ai, https://ml.azure.com, https://*.ml.azure.com,
         https://ai.azure.com, https://*.ai.azure.com
```

Terraform 側で `blob_properties` を管理していると毎回これを削除しようとし、
**適用すると Studio のファイルブラウザが壊れ、Azure が再設定して差分が永久に再発**する。

**対処**: `modules/storage/main.tf` で CORS を管理対象外にしている。

```hcl
lifecycle {
  ignore_changes = [blob_properties[0].cors_rule]
}
```

あわせて `blob_properties` の `cors_rules` 入力自体を削除した。`ignore_changes` は変数で
切り替えられない (静的リストのみ) ため、「入力は受け付けるが黙って無視される」という
矛盾した口を残さないための判断。

### 4.3 AI Services がまるごと再作成されそうになる

plan が `delete, create` になり、そのまま適用するとエンドポイント / アクセスキー / PE が
作り直されるところだった。

```
action_reason: replace_because_cannot_update
replace_paths: [["project_management_enabled"]]
```

**原因**: AI Foundry と紐付けると Azure が `allowProjectManagement: true` に変更する。
Terraform 側が未指定 = `false` のため差分となり、この属性は **ForceNew** なので置換になる。

**対処**: `ai_services_project_management_enabled` を既定 `true` にして実態と揃えた。

> plan で `delete, create` を見たら必ず `replace_paths` を確認すること。
> ```bash
> terraform plan -out=tf.plan && terraform show -json tf.plan | \
>   python3 -c "import json,sys; [print(r['address'], r['change'].get('replace_paths')) for r in json.load(sys.stdin)['resource_changes'] if 'delete' in r['change']['actions']]"
> ```

### 4.4 AI Foundry ポータルが「プライベート ネットワーク アクセスが必要です」になる

```
この Foundry プロジェクトでは、パブリック ネットワーク アクセスが無効になっています。
プライベート エンドポイントを経由して、承認された Azure Virtual Network (VNet) から
のみアクセスできます。適切なネットワークに接続した後、このページを更新してください。
```

**結論: `networkAcls.defaultAction = Deny` だと AI Foundry ポータルは使えない。**
許可 IP を入れても、`bypass = AzureServices` を足しても変わらない。`Allow` にすると消える。

切り分けの過程で潰した仮説 (**すべてシロだった**):

| 検証 | 結果 |
|---|---|
| Hub / Project の `publicNetworkAccess` | Enabled (メッセージに反して Hub は Public だった) |
| RG 内・サブスクリプション全体の全リソース | すべて Enabled。他に該当リソースなし |
| 3 エンドポイントの公開 DNS 解決 + HTTP | すべて解決、200 |
| Entra 認証つきデータ面 API | 404 (= アプリ応答。403 の遮断ではない) |
| ブラウザの出口 IP と許可 IP の一致 | 一致していた |
| `bypass = AzureServices` の追加 | 変化なし |
| v2 プロジェクト側の独自ネットワーク設定 | 存在しない (アカウントの設定を継承) |
| `defaultAction` を `Allow` に変更 | **警告が消えた** |

**警告が出ていたのはどのプロジェクトか。** 本構成には「プロジェクト」が 2 つ存在する (§4.7)。
警告の対象は **v2 プロジェクト `<account>-project`** で、これは AI Services アカウントの
**入れ子リソース**である。つまり制限しているのはそのプロジェクトの**親アカウント**であり、
Hub 側からの「接続 (connection)」の話ではない (Hub と AI Services は未接続のままだった)。

根拠は観測された因果関係。AI Services アカウントの `defaultAction` を変えた瞬間に警告が消えた以上、
警告を出していたページは**そのアカウントに支配されるもの** = v2 プロジェクトだったことになる。
Hub 系 (v1) の `aifp-<suffix>` は AI Services と未接続なので、ACL を変えても影響を受けない。

**ポータルのメッセージ自体も誤解を招く**。`publicNetworkAccess` が Enabled でもこの文言が出る。
ポータルは実際の到達性を試すのではなく、**ネットワーク制限の有無を静的に判定して表示している**
と考えられる。

**トレードオフ**: ポータル利用と AI Services のネットワーク制限は両立しない。
ポータルを使わず AKS 等から API 利用するだけなら `restricted` が最も安全。

### 4.5 plan 時に未確定な値で `count` / `for_each` を分岐させない

`validate` は通るが `plan` で落ちる / 挙動が壊れる類。同一 apply 内で作るリソースの ID は
plan 時点で未確定なため、分岐条件に使えない。

| NG | OK |
|---|---|
| `count = var.subnet_id == null ? 0 : 1` | `count = var.create_private_endpoint ? 1 : 0` (フラグで判定) |
| `lookup(zone_ids, key, null) == null` | `contains(keys(zone_ids), key)` (値ではなくキーの有無) |

前者は `Invalid count argument`、後者は map の値が未確定だと `dynamic` の `for_each` が
未確定になって落ちる。**キーは確定するが値は未確定**という状態を意識する。

### 4.6 destroy が 409 で止まる (入れ子リソース)

```
Error: deleting Account (...): performing AccountsDelete: unexpected status 409 (409 Conflict)
with error: CannotDeleteResource: Cannot delete resource while nested resources exist.
Some existing nested resource IDs include:
'Microsoft.CognitiveServices/accounts/ais-<suffix>/projects/ais-<suffix>-project'.
```

**原因**: `allowProjectManagement = true` により Cognitive Services アカウント配下に
**v2 Foundry プロジェクトが自動生成される** (§4.7 参照)。これは Terraform 管理外なので
state に無く、Terraform は親アカウントだけ消そうとして Azure に拒否される。

destroy は途中まで進むため、**アカウントと入れ子プロジェクトだけが残った状態**で止まる。

**対処**: 入れ子プロジェクトを先に削除してから destroy を再実行する。

```bash
SUB=<subscription-id>; RG=aifsbx-rg; ACC=ais-<suffix>
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACC"

# 入れ子プロジェクトを列挙して削除 (name は "<account>/<project>" 形式で返るため後半を取る)
for p in $(az rest --method get --url "$BASE/projects?api-version=2025-06-01" --query "value[].name" -o tsv); do
  az rest --method delete --url "$BASE/projects/${p##*/}?api-version=2025-06-01"
done

terraform destroy
```

**destroy 後の確認** (論理削除の残骸が課金や名前衝突の原因になるため):

```bash
terraform state list                  # 空であること
az group exists -n $RG                # false であること
az cognitiveservices account list-deleted -o table   # 論理削除の残骸
az keyvault list-deleted -o table                    # 同上
```

Key Vault は `providers.tf` で `purge_soft_delete_on_destroy = true` を設定済みのため
destroy 時に自動パージされる。残っていた場合は `az keyvault purge -n <name>` で削除する。

### 4.7 「プロジェクト」が 2 種類あり、別物である

§4.4 を理解するうえで**最も重要な前提**。ここを取り違えると
「接続もしていない AI Services の設定が、なぜ AI Foundry の画面に効くのか」が理解できない。

#### 4.7.1 混乱の元 — 「AI Foundry」が 3 つの別物を指している

| 呼び方 | 実体 | 備考 |
|---|---|---|
| AI Foundry **ポータル** | `ai.azure.com` という **Web サイト** | ARM リソースではない。単なる閲覧 UI |
| AI Foundry **Hub** | `azurerm_ai_foundry` で作る ARM リソース | 旧 (v1) モデル。実体は Azure ML workspace (kind=Hub) |
| AI Foundry **プロジェクト** | 後述のとおり **2 種類ある** | ポータルは両方を同じ一覧に並べて表示する |

**ポータルは「どのプロジェクトを開いているか」でバックエンドのリソースが変わる。**
画面の見た目が同じでも、裏にいるリソースは別物になり得る。

#### 4.7.2 kind = AIServices のアカウント = AI Foundry リソースそのもの

`azurerm_cognitive_account` に `kind = "AIServices"` を指定して作ると、
**それ自体が現行 (v2) の AI Foundry リソースになる**。`azurerm_ai_foundry` (Hub) は要らない。
v2 プロジェクトが「勝手に生える」のはこのため。

本構成で実際に観測された内容 (**Terraform 側では何も指定していないのに Azure が設定していた**):

| 観測項目 | 値 |
|---|---|
| `allowProjectManagement` | `true` (Terraform 未指定なのに Azure 側で true) |
| `associatedProjects` | `["ais-<suffix>-project"]` |
| 既定プロジェクト | `ais-<suffix>-project` が**アカウント作成と同時刻に自動生成** |
| `isDefault` | `true` |
| エンドポイント | `https://ais-<suffix>.services.ai.azure.com/api/projects/<project>` |
| ポータル | `ai.azure.com` の一覧に出現し、実際にそこを開いていた (§4.4) |

**ただし用意されるのは「器」だけで、「使える AI」にはならない。**

| | 自動で用意される | 別途必要 |
|---|---|---|
| Foundry プロジェクトの器 | ✅ | |
| `services.ai.azure.com` エンドポイント | ✅ | |
| ポータルへの表示 | ✅ | |
| **モデルのデプロイ** | ❌ | **手動でデプロイが必要** (AzureRM 未対応、§5) |
| Hub 系機能 (managed compute / prompt flow / 評価) | ❌ | Hub (v1) が必要 |

実際、本構成のアカウントに対して `/openai/deployments` を叩くと空 (404) だった。
GPT 等を使うにはポータルまたは az CLI でモデルデプロイを作る必要がある。

この「自動でついてくる」性質が、以下 2 つのハマりの直接の原因になっている:

- `allowProjectManagement` が **ForceNew** のため、実態と揃えないとアカウントごと再作成される (§4.3)
- 自動生成された入れ子プロジェクトが **destroy を 409 で止める** (§4.6)

#### 4.7.3 2 種類のプロジェクト

| | v1 (Hub ベース) | v2 (アカウント入れ子) |
|---|---|---|
| ARM 種別 | `Microsoft.MachineLearningServices/workspaces` (kind=Project) | `Microsoft.CognitiveServices/accounts/projects` |
| 本構成での名前 | `aifp-<suffix>-01` | `ais-<suffix>/ais-<suffix>-project` |
| 作られ方 | `azurerm_ai_foundry_project` で明示的に作成 | `allowProjectManagement = true` により **Azure が自動生成** (Terraform 管理外) |
| 親 | Hub (`aif-<suffix>-01`) | **AI Services アカウント** (`ais-<suffix>`) |
| ネットワーク制限の支配元 | 自身の `publicNetworkAccess` | **親アカウントの `networkAcls` / `publicNetworkAccess`** |
| AI Services との関係 | **connection を張らないと繋がらない** (本構成では未接続だった) | **親子。最初から一体で、接続は不要** |

#### 4.7.4 本構成の実際の姿

```
Azure リソース
│
├── aif-<suffix>-01  (Hub)                          ← Terraform が作成
│   └── aifp-<suffix>-01  (プロジェクト v1)          ← Terraform が作成
│        └─ AI Services への connection : なし ❌
│
└── ais-<suffix>  (AI Services アカウント)           ← Terraform が作成
     │   ネットワーク設定: networkAcls.defaultAction
     └── ais-<suffix>-project  (プロジェクト v2)      ← Azure が自動生成
          ↑ 親の「中身」なので、親の設定がそのまま効く
```

```
ai.azure.com (Web サイト) が表示するプロジェクト一覧
   ├─ aifp-<suffix>-01        (Hub 系 v1)
   └─ ais-<suffix>-project    (AI Services 系 v2)   ← §4.4 で開いていたのはこちら
```

#### 4.7.5 §4.4 で何が起きていたか

**ポータルで開いていたのは v2 のプロジェクトで、それは AI Services アカウントの中身そのもの。**
だから AI Services のネットワーク制限でブロックされた。それだけの話。

「接続していないのに、なぜ AI Services の設定が効くのか」の答えは **接続する必要がないから**。
v2 プロジェクトは AI Services の**部品**であって別リソースではない。
フォルダの権限がその中のファイルに効くのと同じで、間に connection は介在しない。

Terraform で作った Hub と v1 プロジェクトは、**一覧には出ていたが開いていなかった**だけ。

**v2 を開いていたと断定できる根拠**は、観測された因果関係:

- v1 を開いていたなら → v1 は AI Services と未接続なので、AI Services の ACL を変えても無反応のはず
- v2 を開いていたなら → 親の設定がそのまま効くので、変えれば直る

実際に `defaultAction` を `Allow` にした瞬間に警告が消えたため、開いていたのは v2 で確定。

#### 4.7.6 どちらを見ているかの判別方法

**ポータルの URL に開いているプロジェクトのリソース ID が含まれる**ので、これが一番速い。

| URL に含まれる文字列 | 開いているもの |
|---|---|
| `.../Microsoft.CognitiveServices/accounts/...` | **v2** (AI Services の中身) |
| `.../Microsoft.MachineLearningServices/workspaces/...` | **v1** (Hub 系) |

CLI で両系統を棚卸しする場合:

```bash
SUB=<subscription-id>; RG=<rg>

# v1: Hub / Project と、その connection (空なら AI Services と未接続)
az resource list --resource-type Microsoft.MachineLearningServices/workspaces \
  --query "[].{name:name, kind:kind}" -o table
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.MachineLearningServices/workspaces/<hub>/connections?api-version=2024-10-01" \
  --query "value[].{name:name, category:properties.category, target:properties.target}" -o table

# v2: AI Services アカウント配下のプロジェクト
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/<account>/projects?api-version=2025-06-01" \
  --query "value[].{name:name, isDefault:properties.isDefault}" -o table

# v2 が生える条件 (true なら自動生成される)
az cognitiveservices account show -g $RG -n <account> \
  --query "properties.{allowProjectManagement:allowProjectManagement, associatedProjects:associatedProjects}"
```

#### 4.7.7 設計上の含意

**要件次第では Hub (v1) は不要。** 推論エンドポイントを使うだけなら、
AI Services アカウント + 自動生成される v2 プロジェクトで完結する。
Hub が要るのは managed compute、prompt flow、評価など Hub ベースの機能を使う場合。

本構成は v1 と v2 を**両方作ったうえで繋いでいない**状態なので、次に触る際は先に方針を決めること:

1. **v2 のみにする** — `azurerm_ai_foundry` / `azurerm_ai_foundry_project` を削除。
   Hub 用の Storage / Key Vault も不要になり、構成が大幅に簡素化される
2. **v1 を活かす** — Hub から AI Services への connection を追加する (§5)

なお v2 プロジェクトは Terraform 管理外のため、**destroy を 409 で止める原因**にもなる (§4.6)。

---

## 5. 既知の課題 / TODO

- **Hub と AI Services が接続されていない (§4.7)。** 両ワークスペースの connections が空で、
  現状は「Hub 系 (v1)」と「AI Services 系 (v2)」が独立した 2 系統になっている。
  Hub 側から AI Services のモデルを使うには connection の追加が必要。
  そもそも Hub が要るのかを含めて方針を決めること (§4.7.7)。

  ```bash
  az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/aifsbx-rg/providers/Microsoft.MachineLearningServices/workspaces/aif-<suffix>/connections?api-version=2024-10-01"
  ```

- **v2 Foundry プロジェクトが自動生成される。** `allowProjectManagement = true` により
  Cognitive Services アカウント配下に `<account>-project` が自動作成される (Terraform 管理外)。
  ポータルで見えるのは主にこちら。**destroy を 409 で止める原因になる** (§4.6)。

  ```bash
  az rest --method get --url ".../accounts/<name>/projects?api-version=2025-06-01"
  ```

- **model deployment は AzureRM 未対応。** Hub / Project 作成後にポータルまたは az CLI で手動作成する。
- `enable_static_website` はモジュールに実装済みだが、現在どの呼び出し元も使っていない。

---

## 6. トラブルシュート用 CLI

```bash
RG=aifsbx-rg; ACC=ais-<suffix>

# 公開範囲を総ざらい (どのリソースが閉じているか)
for id in $(az resource list -g $RG --query "[].id" -o tsv); do
  pna=$(az resource show --ids "$id" --query "properties.publicNetworkAccess" -o tsv 2>/dev/null)
  [ -n "$pna" ] && echo "$pna  $(basename $id)"
done

# ネットワーク設定
az cognitiveservices account show -g $RG -n $ACC \
  --query "properties.{pna:publicNetworkAccess, acls:networkAcls, proj:allowProjectManagement}"

# データ面の到達性 (403 ならネットワーク遮断 / 401・404 ならネットワークは通っている)
curl -s -o /dev/null -w "%{http_code}\n" "https://$ACC.services.ai.azure.com/"

# ロール割り当ての実態 (409 の調査用)
az role assignment list --scope "<resource-id>" \
  --query "[].{name:name, role:roleDefinitionName, principal:principalId}" -o table

# Azure が設定した CORS
az storage account blob-service-properties show --account-name <sa> -g $RG --query cors
```

**判定のコツ**: HTTP ステータスで切り分ける。`403` はネットワーク遮断、
`401` / `404` はネットワークを通過してアプリ層まで届いている (= ネットワークは無罪)。
