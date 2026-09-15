# managed_network とは何か — 受信と送信を分けて考える

> `AI Foundry の public_network_access を無効化して PE を作る` までは理解できたが
> `managed_network` と `Storage の閉域化` の関係が分からない、という疑問への回答。

---

## 1. 一番大事な区別 — PE は「受信」、managed_network は「送信」

この 2 つは**まったく別の方向の話**で、互いに代替にならない。

| | 設定 | 何を制御するか | 向き |
|---|---|---|---|
| `public_network_access = "Disabled"` + Private Endpoint | Hub / Storage / Key Vault それぞれ | **誰がそのリソースに入ってこられるか** | **受信 (inbound)** |
| `managed_network { isolation_mode = ... }` | Hub のみ | **Hub の中で動く計算リソースが、どこへ出ていけるか** | **送信 (outbound)** |

```
       ┌──────────── 受信 (inbound) ────────────┐
       │  「誰が Hub を触れるか」                 │
       │  public_network_access + PE で制御      │
       │                                        │
  利用者 / 踏み台VM ──PE──► ┌─────────────┐
                            │ AI Foundry  │
                            │    Hub      │
                            └──────┬──────┘
                                   │
       ┌─────────── 送信 (outbound) ──────────┐
       │  「Hub の計算が、どこへ出ていけるか」     │
       │  managed_network で制御                │
       │                                       │
                                   ▼
                     ┌──── Microsoft 管理のサブスク ────┐
                     │   マネージド VNet (Hub 専用)      │
                     │   ├ compute instance            │
                     │   ├ prompt flow ランタイム        │
                     │   └ 評価ジョブ                    │
                     └──────────┬──────────────────────┘
                                │ マネージド Private Endpoint
                                │ (Azure が自動作成)
                                ▼
                  閉域化した Storage / Key Vault
```

---

## 2. なぜ Hub に「送信」の概念があるのか

**Hub は設定の箱ではなく、実際に計算リソースを動かすから。**

Hub 配下で動くもの:

- compute instance / compute cluster (managed compute)
- **prompt flow の実行ランタイム**
- **評価 (evaluation) ジョブ**
- serverless Spark

**これらはあなたの VNet では動かない。Microsoft 管理のサブスクリプション内で動く。**

ここで問題が発生する。Storage を閉域化 (`publicNetworkAccess = Disabled`) すると、
その Storage に入れるのは「PE がある VNet の中」だけになる。
**しかし Hub の計算リソースはあなたの VNet の中にいない。**

```
  あなたの VNet                 Microsoft 管理のサブスク
  ┌──────────────┐             ┌────────────────────┐
  │ probe VM     │             │  prompt flow 実行   │
  │   │          │             │       │            │
  │   │ PE       │             │       │ ????       │
  │   ▼          │             │       ▼            │
  └───┼──────────┘             └───────┼────────────┘
      │                                │
      ▼                                ▼
  ┌──────────────────────────────────────────┐
  │  Storage (publicNetworkAccess = Disabled) │
  │  PE のある VNet からしか入れない             │
  └──────────────────────────────────────────┘
```

この `????` を埋めるのが `managed_network`。

---

## 3. managed_network を有効にすると何が起きるか

**Azure がその Hub 専用のマネージド VNet を作り、依存リソースへの
マネージド Private Endpoint を自動で張る。**

本構成 (`isolation_mode = "AllowInternetOutbound"`) で実際に自動作成されたもの:

```bash
az rest --method get --url ".../workspaces/aif-aissbx/outboundRules?api-version=2024-10-01"
```

| status | type | category | 宛先 |
|---|---|---|---|
| Inactive | PrivateEndpoint | **Required** | `staissbxhubxxxxx` / **blob** |
| Inactive | PrivateEndpoint | **Required** | `staissbxhubxxxxx` / **file** |
| Inactive | PrivateEndpoint | **Required** | `kv-aissbx-xxxxx` / **vault** |
| Inactive | PrivateEndpoint | **Required** | `aif-aissbx` / **amlworkspace** |

**`category: Required` = Azure が「この Hub が動くのに必須」と判断して勝手に作ったもの。**
自分で書く必要はない。`managed_network` ブロックを置くだけで付いてくる。

Hub の ARM 表現:

```json
"managedNetwork": {
  "isolationMode": "AllowInternetOutbound",
  "networkId": "<MANAGED_NETWORK_ID>"
}
```

### 3 つの isolation mode

| mode | マネージド VNet | 送信の扱い | 使いどころ |
|---|---|---|---|
| **`Disabled`** (ブロック省略時) | **作らない** | 計算は Microsoft の共有ネットワークから公開エンドポイント経由で出る | 依存リソースを閉じないなら十分 |
| **`AllowInternetOutbound`** (本構成) | 作る | インターネットへの送信は自由。依存リソースへはマネージド PE | 依存リソースを閉じつつ、pip install 等でインターネットも使いたい |
| **`AllowOnlyApprovedOutbound`** | 作る | **承認した宛先のみ**。それ以外は遮断 | 完全閉域。FQDN ルールを自分で足す必要があり運用が重い |

Terraform では:

```hcl
# hub.tf
dynamic "managed_network" {
  for_each = local.hub_managed_network_isolation_mode == null ? [] : [local.hub_managed_network_isolation_mode]
  content {
    isolation_mode = managed_network.value
  }
}
```

`locals.tf` で `hub_dependencies_private` から導出している:

```hcl
hub_managed_network_isolation_mode = local.hub_deps_private ? "AllowInternetOutbound" : null
```

---

## 4. ★ 遅延プロビジョニング — 設定しただけでは作られない

**`isolation_mode` を設定しても、マネージド VNet はその場では構築されない。**

実測:

```bash
$ az rest ... --query "properties.managedNetwork.status"
(null)                     # ← 未プロビジョニング

$ az rest ... /outboundRules
status: "Inactive"         # ← 4 本とも Inactive
```

マネージド VNet が実際に構築されるのは:

- 初めて compute instance / cluster を作ったとき
- 初めて serverless なジョブを流したとき
- 明示的に provision 操作を呼んだとき (`az ml workspace provision-network`)

**つまり「宣言はしたが、まだ何も動いていない」状態が普通にある。**
`Inactive` を見て「設定が効いていない」と誤読しないこと。

---

## 5. ★ 訂正 — Hub の作成に managed_network は不要だった

**初版の記述は誤りだったので訂正する。**

当初「`managed_network` + `bypass = AzureServices` をセットにすれば Hub 作成が通る」と
書いていたが、**因果を検証していなかった**。A/B テストで確かめた結果:

### A/B テスト

同じ **private Storage / private Key Vault** に対して、
`managedNetwork.isolationMode = "Disabled"` (マネージド VNet なし) の Hub を作成:

```bash
az rest --method put --url ".../workspaces/abtest-hub-nomn?api-version=2024-10-01" --body '{
  "location": "japaneast",
  "kind": "Hub",
  "identity": { "type": "SystemAssigned" },
  "properties": {
    "storageAccount": "<private な Storage の ID>",
    "keyVault":       "<private な Key Vault の ID>",
    "publicNetworkAccess": "Disabled",
    "managedNetwork": { "isolationMode": "Disabled" }
  }
}'
```

**結果:**

```json
{ "mn": "Disabled", "pna": "Disabled", "prov": "Succeeded" }
```

```bash
$ az rest ... /outboundRules
{ "value": [] }          # マネージド PE は 1 本も作られない
```

> ### ✅ **Hub の「作成」に managed_network は要らない。**
> private Storage / private Key Vault に対しても、マネージド VNet なしで作成できる。

### なぜ作成できるのか

**Hub の作成は ARM (コントロールプレーン) 操作で、Storage のデータ面に触らないから。**

| 操作 | 経路 | `publicNetworkAccess = Disabled` の影響 |
|---|---|---|
| Hub リソースの作成 | ARM | **なし** |
| Storage の SAS / キー取得 (`listKeys`) | **Storage のコントロールプレーン** | **なし** |
| Key Vault への Secret 書き込み | Key Vault データ面 | あり (bypass で通していると推測) |
| Blob の読み書き (データセット / prompt flow) | **Storage データ面** | **あり** |

Hub 作成時に Key Vault へ入る 3 本の Secret は Storage の **SAS** だが、
SAS の発行自体はコントロールプレーン操作なので Storage を閉じていても行える
([04-storage-and-keyvault.md](04-storage-and-keyvault.md) §3.1)。

### では何のために managed_network が要るのか

**作成時ではなく実行時。** Storage を閉じた状態で以下をやるときに経路が必要になる:

- prompt flow を実行する
- 評価 (evaluation) ジョブを流す
- compute instance からデータセットを読む
- Studio のファイルブラウザで blob を開く

これらは実際に Storage の**データ面**を叩く。

> **本検証ではそこまで実行していない [未検証]。**
> 確認済みなのは「Hub / Project が作成でき、plan が `No changes` になる」ところまで。
> prompt flow / 評価を閉域で動かす検証は別途必要。

---

## 6. bypass = AzureServices との関係

`managed_network` とは**別レイヤーの保険**。混同しやすい。

| | どこの設定か | 何をするか |
|---|---|---|
| `managed_network` | **Hub 側** | Hub 専用の VNet を作り、そこから依存リソースへ PE を張る |
| `bypass = "AzureServices"` | **Storage / Key Vault 側** | 「信頼された Azure サービス」からのアクセスを ACL に関係なく通す |

本構成では両方を設定している:

```hcl
# hub.tf — Storage 側
dynamic "network_rules" {
  for_each = local.hub_deps_private ? [1] : []
  content {
    default_action = "Deny"
    bypass         = ["AzureServices"]   # ← 信頼済みサービス経路
    ...
  }
}

# hub.tf — Key Vault 側
dynamic "network_acls" {
  for_each = local.hub_deps_private ? [1] : []
  content {
    default_action = "Deny"
    bypass         = "AzureServices"
    ...
  }
}
```

> **注意: `publicNetworkAccess = Disabled` のとき `bypass` が本当に効くかは
> MS Docs 上あいまいで、本検証でも切り分けていない [未検証]。**
> MS Docs には「Exceptions (bypass) は `Disabled` を選んでいるときも表示される」と
> あるため効きうると読めるが、実証はしていない。

---

## 7. 整理 — 3 つのレイヤーに分けて考える

「Storage の閉域化」を 1 つの話だと思うと混乱する。**3 層に分ける。**

| 層 | 設定 | 問い | 本構成での実装 | 検証状況 |
|---|---|---|---|---|
| **① Storage の受信** | Storage の `public_network_access_enabled = false` + blob/file の PE | 誰が Storage に入れるか | `hub.tf` の `azurerm_storage_account` + `azurerm_private_endpoint.hub_storage` | ✅ VNet 外から 403 を確認 |
| **② Hub の受信** | Hub の `public_network_access = "Disabled"` + amlworkspace の PE | 誰が Hub に入れるか | `azurerm_ai_foundry` + `azurerm_private_endpoint.hub` | ✅ 作成成功・PE 登録確認 |
| **③ Hub の送信** | Hub の `managed_network { isolation_mode }` | Hub の計算が Storage にどう出ていくか | `managed_network` ブロック | ⚠️ 宣言のみ。**未プロビジョニング・未検証** |

**①と②は独立。** どちらか一方だけ閉じることもできる。

**③は①をやったときに初めて問題になる。** そして**③が効くのは作成時ではなく実行時**。

### だから何をすればいいのか

| やりたいこと | 必要な設定 |
|---|---|
| 推論エンドポイントだけ使う | **そもそも Hub も Storage も不要。** v2 (`kind = AIServices`) のみで完結 ([04](docs/04-storage-and-keyvault.md) §1) |
| Hub を作るが Storage は開けておく | ①なし / ②あり / ③なし |
| Hub も Storage も閉じる。ただし prompt flow 等は使わない | ①あり / ②あり / ③は無くても作成は通る (§5 で実証) |
| Hub も Storage も閉じて prompt flow / 評価も動かす | ①あり / ②あり / **③あり** + マネージド VNet のプロビジョニングが必要 |

**「Storage だけ閉じて Hub の実行系も使う」が一番壊れやすい組み合わせ。**
その場合に ③ が要る、という位置づけ。

---

## 8. 「VNet 統合」とは違うのか

**名前が似ているが別物。** App Service の VNet 統合や、
新しい Foundry (v2) の **virtual network injection** とも違う。

| | 誰の VNet か | あなたが管理するか |
|---|---|---|
| **Hub の `managed_network` (v1)** | **Microsoft 管理のサブスク内**の VNet | ❌ 中身は見えない。outbound rules だけ管理できる |
| **Foundry v2 の virtual network injection** | **あなたの VNet** のサブネット (`Microsoft.App/environments` に委任、/27 以上) | ✅ 自分の VNet |
| App Service の VNet 統合 | あなたの VNet | ✅ |

v2 の virtual network injection は、Agent Service のクライアントを
**あなたのサブネットに注入する**方式で、トラフィックが自分の VNet 境界に留まる。
`managed_network` は「Microsoft 側に Hub 専用の VNet を作ってもらう」方式で、
中身は不可視。

> v2 の injection には制約がある。
> 「**outbound networking は後から変更できない**。委任サブネットの変更も不可。
> 既存デプロイに outbound VNet injection を追加することもできず、**再デプロイが必要**」
>
> 出典: [How to configure network isolation for Microsoft Foundry](https://learn.microsoft.com/azure/ai-foundry/how-to/configure-private-link)

本構成は v1 Hub の `managed_network` のみを扱っており、
v2 の virtual network injection は使っていない。

---

## 9. 確認コマンド

```bash
SUB=<subscription-id>; RG=rg-aissbx

# isolation mode と networkId
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.MachineLearningServices/workspaces/aif-aissbx?api-version=2024-10-01" \
  --query "properties.managedNetwork"

# 自動作成された outbound rules (マネージド PE)
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.MachineLearningServices/workspaces/aif-aissbx/outboundRules?api-version=2024-10-01" \
  --query "value[].{name:name, type:properties.type, category:properties.category, status:properties.status, target:properties.destination.subresourceTarget}" -o table

# status が Inactive のままなら未プロビジョニング。明示的に構築する場合:
#   az extension add -n ml
#   az ml workspace provision-network -g $RG -n aif-aissbx
```
