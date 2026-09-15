# AI Foundry と Storage / Key Vault

## 1. 前提 — 「AI Foundry」は 2 系統ある

ここを取り違えると Storage / Key Vault の必要性の議論が噛み合わない。

| | v1 (Hub ベース) | v2 (アカウント入れ子) |
|---|---|---|
| ARM 種別 | `Microsoft.MachineLearningServices/workspaces` (kind=Hub) | `Microsoft.CognitiveServices/accounts/projects` |
| Terraform | `azurerm_ai_foundry` / `azurerm_ai_foundry_project` | `azurerm_cognitive_account` (kind=`AIServices`) + `azurerm_cognitive_account_project` |
| 本構成の名前 | `aif-aissbx` / `aifp-aissbx` | `ais-aissbx-<suffix>` / `proj-aissbx` |
| **Storage Account** | **必須** | **不要** |
| **Key Vault** | **必須** | **不要** |
| ネットワーク制限の支配元 | 自身の `publicNetworkAccess` | **親アカウント**の `networkAcls` / `publicNetworkAccess` |
| 使う機能 | managed compute / prompt flow / 評価 | 推論エンドポイント / Agent / Playground |

> ### 最短の答え
>
> **推論エンドポイントを使うだけなら Hub (v1) はまるごと不要。**
> `kind = AIServices` のアカウント + v2 プロジェクトで完結し、
> **Storage も Key Vault も出てこない。** そうすれば
> 「Storage を閉じてよいか」「Secret はどうなるか」という問題自体が消える。
>
> 本構成では `enable_foundry_hub = false` にすると v2 だけの姿になる。

Hub が要るのは managed compute、prompt flow、評価など Hub ベースの機能を使う場合だけ。

---

## 2. Storage Account の閉域化 — 「してはいけない」のか「必須」なのか

### 結論

| 質問 | 回答 |
|---|---|
| 閉域化してはいけない? | **いいえ。** MS Docs は Storage を Private Link で閉じる前提で書かれている |
| 閉域化は必須? | **いいえ。** Hub は public な Storage でも動く |
| 注意点 | **「Storage だけ単独で閉じる」が一番壊れやすい** |

### 2.1 MS Docs は「閉じる」前提

> "PaaS resources—such as the Microsoft Foundry project, **storage**, Key Vault,
> container registry, and monitoring—are **isolated using Private Link**."

> "Private endpoints to Azure AI Search, **Azure Storage**, and Azure CosmosDB are
> **NOT auto-created** when you deploy your Foundry resource. Please ensure to
> create private endpoints to these resources **separately**."

つまり Storage の PE は「作ってはいけないもの」ではなく
**「自動では作られないので自分で作るもの」**。

> 出典: [How to configure network isolation for Microsoft Foundry](https://learn.microsoft.com/azure/ai-foundry/how-to/configure-private-link)

### 2.2 壊れる条件は「到達経路を用意せずに Storage だけ閉じる」こと

Hub は Storage を実際に使う (データセット / prompt flow のファイル / 評価結果)。
経路が無いとプロジェクト作成や prompt flow が失敗する。

**閉じるなら以下とセットにする:**

| 対処 | 本構成での実装 | いつ効くか |
|---|---|---|
| **blob と file の両方**の PE とゾーン | `azurerm_private_endpoint.hub_storage` (for_each) | 常時 |
| `shared_access_key_enabled = true` を残す | Hub の既定 datastore が SAS を必要とする (§3) | Hub 作成時 |
| Storage の `network_rules` に `bypass = ["AzureServices"]` | `hub.tf` の `network_rules` ブロック | 信頼済みサービス経路 |
| Hub の `managed_network` を有効化 | `hub_managed_network_isolation_mode = "AllowInternetOutbound"` | **実行時のみ** (§2.3) |

### 2.3 ★ 訂正 — managed_network は Hub 作成の条件ではない

**初版では「`managed_network` + `bypass` をセットにすれば Hub 作成が通る」と書いたが、
因果を検証していなかった。A/B テストで誤りと判明した。**

同じ private Storage / private Key Vault に対して
`managedNetwork.isolationMode = "Disabled"` の Hub を作ったところ、**成功した**:

```json
{ "mn": "Disabled", "pna": "Disabled", "prov": "Succeeded" }
```

**Hub の作成は ARM (コントロールプレーン) 操作で、Storage のデータ面に触らない。**
Key Vault に入る SAS の発行も Storage のコントロールプレーン操作。だから閉じていても作れる。

`managed_network` が要るのは**実行時** — Hub の計算リソース
(prompt flow / 評価 / compute instance) が閉じた Storage の**データ面**を
叩くときの経路として。**本検証ではそこまで実行していない [未検証]。**

**受信 (PE) と送信 (managed_network) は別の話。**
詳細な解説は [07-managed-network.md](07-managed-network.md)。

### 2.4 実測 — この構成で Hub 作成は通った

```
azurerm_ai_foundry.this[0]: Creation complete after 1m15s
```

| リソース | 状態 |
|---|---|
| Storage | `publicNetworkAccess = Disabled` |
| Key Vault | `publicNetworkAccess = Disabled` |
| Hub | `publicNetworkAccess = Disabled` + `managedNetwork = AllowInternetOutbound` (ただし未プロビジョニング) |

VNet 外から Storage のデータ面を叩くと **403**、Key Vault は **401** (未認証のため)。

### 2.5 副作用 — Terraform からコンテナを作れなくなる

**Storage のデータ面 (コンテナ作成) は PE / ファイアウォールの影響を受ける。**
閉域化すると terraform 実行端末から到達できない。

本構成では `local.hub_storage_container_names = []` として回避している。
コンテナが必要なら **ARM コントロールプレーン経由 (azapi)** で作る。
同リポジトリに前例あり:

```
test/storage-adf-psql-function-aks-relation/terraform/envs/spoke-subscription/main.tf
  azapi_resource "deployments"
```

### 2.6 CORS は Terraform 管理外にする

AI Foundry は Hub に紐付けた Storage へ **Studio 用の CORS ルールを自動設定**する
(`https://ai.azure.com` / `https://ml.azure.com` 等のオリジン)。

Terraform 側で管理すると毎回削除しようとして差分が出続け、
**適用すると Studio のファイルブラウザが壊れ、Azure が再設定して差分が永久に再発**する。

```hcl
# hub.tf
lifecycle {
  ignore_changes = [blob_properties[0].cors_rule]
}
```

---

## 3. Key Vault の Secret はどうなるのか

### 結論

**ネットワークの閉域化と Secret の有無はまったくの別軸。**
閉域化しても Secret は**そのまま残り、そのまま使われる**。

### 3.1 ★ いつ Secret が登録されるのか (実測で想定が外れた)

当初は「API キー認証の connection を作ったときだけ」と考えていたが、**実測はそれより広かった**。

**connection を 1 つも作っていないのに、Hub を作った時点で 3 本入っていた:**

| Secret 名 | contentType | 中身 |
|---|---|---|
| `<guid>-workspaceblobstore00010101000000000` | `application/vnd.ms-StorageAccountAccessKey` | Storage の **SAS トークン** |
| `<guid>-workspaceartifactstore00010101000000000` | 同上 | 同上 |
| `<guid>-workspaceworkingdirectory00010101000000000` | 同上 | 同上 |

値は `sv=2025-...` で始まる 108 文字の SAS。
**生のアカウントキーではない** (Storage のアカウントキー先頭 `0p7lnqk2` と一致しない)。

つまり Secret が生まれる経路は **2 つ**ある:

| 経路 | いつ | 内容 |
|---|---|---|
| **① Hub の既定 datastore** | **Hub 作成時に自動。connection は不要** | バックエンド Storage の SAS (3 本) |
| ② connection | Entra ID 以外の認証で connection を作ったとき | API キー / 接続文字列 / PAT |

②は認証方式次第で作られない:

| connection の認証方式 | Secret |
|---|---|
| API キー / 接続文字列 / PAT (Git, Hugging Face 等) | **作られる** |
| Entra ID (マネージド ID) パススルー | **作られない** |

### 3.2 アクセス制御

Hub / Project の MSI には Key Vault へのアクセスが**自動付与**される。

| プリンシパル | ロール | スコープ |
|---|---|---|
| Hub MSI | `Key Vault Administrator` | Key Vault |
| Hub MSI | `Storage Blob Data Contributor` / `Storage File Data Privileged Contributor` | Storage |
| Project MSI | 上記 + `Storage Account Contributor` / `Reader` / `Azure AI Administrator` | 各スコープ |

**Terraform でこれらを宣言してはいけない。** 重複して
`409 RoleAssignmentExists` になる (`ai/ai_foundry` で実測済み)。

利用者自身に Key Vault の権限は付かない。
Foundry 上の connection オブジェクトへの権限を通じて「使える」だけで、
Secret の値を直接見られるわけではない。

> **Key Vault を自分で紐づけない場合、接続情報は Microsoft 管理の Key Vault
> (サブスクリプション外) に保存される。** 自分の Key Vault を指定するのは
> 「サブスクリプション内に閉じ込める」ための操作でもある。
>
> 出典: [Set up an Azure Key Vault Connection](https://learn.microsoft.com/azure/ai-foundry/how-to/set-up-key-vault-connection)

### 3.3 閉域化したら Secret はどうなるか

| 質問 | 回答 |
|---|---|
| Secret はどうなる? | **そのまま残り、そのまま使われる。**閉域化では何も変化しない |
| 使わなくなる? | いいえ。既定 datastore の 3 本は Hub がある限り使われ続ける |
| 不要になる? | いいえ。**ただし v1 Hub を使わない (v2 のみ) なら Key Vault ごと不要** (§1) |
| 影響は? | **Secret そのものへの影響はない。影響があるのは「Key Vault への到達経路」だけ** |

閉域化で気にすべきなのは Secret の中身ではなく、
**Key Vault を閉じたときに Hub / Project の MSI が到達できるか**のほう。

本構成では:

- Key Vault に `vault` の PE + `privatelink.vaultcore.azure.net`
- `network_acls` に `bypass = "AzureServices"` を残して信頼済みサービス経路を確保

実測では、この状態で Hub 作成は成功し、Secret も正常に書き込まれた。
VNet 内からは PE 経由 + Entra ID 認証で Secret を読めることも確認済み。

### 3.4 Secret を減らしたいなら

**ネットワークではなく認証方式を変える。** 閉域化とは独立した、本質的な対処。

| 対象 | 方法 | 効果 |
|---|---|---|
| ①既定 datastore の 3 本 | Storage の `shared_access_key_enabled = false` にする | SAS が作れなくなり Secret が消える。**ただし Hub 作成自体が失敗しうる。本構成は `true` のまま** **[未検証]** |
| ②connection | connection を Entra ID (マネージド ID) ベースで作る | Secret 自体が作られない |
| 両方 | **v1 Hub をやめて v2 のみにする** | **Key Vault ごと不要になる** |

---

## 4. 確認コマンド

```bash
RG=rg-aissbx

# 公開範囲を総ざらい
for id in $(az resource list -g $RG --query "[].id" -o tsv); do
  pna=$(az resource show --ids "$id" --query "properties.publicNetworkAccess" -o tsv 2>/dev/null)
  [ -n "$pna" ] && echo "$pna  $(basename $id)"
done

# Key Vault の Secret 一覧 (PE 経由でしか読めないので VNet 内の VM から)
cat > /tmp/kv.sh <<'EOS'
IMDS="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01"
TOK=$(curl -s -H Metadata:true "$IMDS&resource=https%3A%2F%2Fvault.azure.net" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
curl -s "https://kv-aissbx-xxxxx.vault.azure.net/secrets?api-version=7.4" \
  -H "Authorization: Bearer $TOK" | python3 -m json.tool
EOS
az vm run-command invoke -g $RG -n vm-aissbx-probe --command-id RunShellScript \
  --scripts "@/tmp/kv.sh" --query "value[0].message" -o tsv

# Azure が設定した CORS
az storage account blob-service-properties show --account-name staissbxhubxxxxx -g $RG --query cors

# Hub の connection (空なら AI Services と未接続)
az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/$RG/providers/Microsoft.MachineLearningServices/workspaces/aif-aissbx/connections?api-version=2024-10-01"
```
