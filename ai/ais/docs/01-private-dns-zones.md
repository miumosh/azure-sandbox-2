# Private DNS Zone — 閉域化の本体

## 1. なぜ Private DNS Zone が本体なのか

**Private Endpoint は「Private にする装置」ではなく「Private な宛先を用意する装置」。**
実際に Private を通るかどうかはクライアントの名前解決で決まる。

閉域経路が成立するには 2 つが揃う必要がある:

1. クライアントが引くホスト名に対応するゾーンが存在する
2. そのゾーンが**呼び出し元の VNet にリンクされている**

### ゾーンが足りないとどうなるか

| `publicNetworkAccess` | ゾーン不足時の挙動 |
|---|---|
| **Disabled** (本構成) | 名前解決できず**到達不能**。すぐ気づく |
| Enabled | **公開 IP に解決され、黙ってインターネット経由になる。エラーが出ないので気づけない** |

後者が本当に怖い。「PE を作ったから閉域化できている」と思い込んだまま、
実際の通信はインターネットを通り続ける。

---

## 2. この構成で必要だったゾーン (8 本)

```hcl
# locals.tf
private_dns_zone_names = {
  cognitiveservices = "privatelink.cognitiveservices.azure.com"
  openai            = "privatelink.openai.azure.com"
  services_ai       = "privatelink.services.ai.azure.com"
  azureml           = "privatelink.api.azureml.ms"
  azureml_notebooks = "privatelink.notebooks.azure.net"
  blob              = "privatelink.blob.core.windows.net"
  file              = "privatelink.file.core.windows.net"
  vault             = "privatelink.vaultcore.azure.net"
}
```

### 2.1 Cognitive アカウント (Foundry Tools)

PE の subresource は **`account` の 1 種類しかない**が、
クライアントが引くホスト名は kind によって変わる。

| kind | クライアントが引くホスト名 | 必要なゾーン |
|---|---|---|
| `SpeechServices` | `<sub>.cognitiveservices.azure.com` | `privatelink.cognitiveservices.azure.com` |
| `OpenAI` | `<sub>.openai.azure.com`<br>`<sub>.cognitiveservices.azure.com` | `privatelink.openai.azure.com`<br>`privatelink.cognitiveservices.azure.com` |
| `AIServices` | `<sub>.services.ai.azure.com`<br>`<sub>.openai.azure.com`<br>`<sub>.cognitiveservices.azure.com` | 上記 3 本すべて |

> 出典: [Azure Private Endpoint private DNS zone values](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)
>
> "Foundry Tools (Microsoft.CognitiveServices/accounts) / **account** /
> `privatelink.cognitiveservices.azure.com`, `privatelink.openai.azure.com`,
> `privatelink.services.ai.azure.com`"
>
> "A Foundry resource **can expose all three endpoints**. Configure DNS for each
> endpoint that your workload uses."

SDK とホスト名の対応:

| SDK | 引くホスト名 |
|---|---|
| Speech SDK / Vision / Language / Content Safety / 各種 REST | `<sub>.cognitiveservices.azure.com` |
| Azure OpenAI SDK (`AzureOpenAI`, `openai` パッケージ) | `<sub>.openai.azure.com` |
| Azure AI Inference SDK / Foundry Projects SDK | `<sub>.services.ai.azure.com` |

### 2.2 AI Foundry Hub (v1) とバックエンド

| リソース | subresource | ゾーン |
|---|---|---|
| AI Foundry Hub (`Microsoft.MachineLearningServices/workspaces`) | `amlworkspace` | `privatelink.api.azureml.ms`<br>`privatelink.notebooks.azure.net` |
| Storage Account | `blob` / `file` | `privatelink.blob.core.windows.net`<br>`privatelink.file.core.windows.net` |
| Key Vault | `vault` | `privatelink.vaultcore.azure.net` |

Hub は PE 1 個 (`amlworkspace`) だが **ゾーンは 2 本セットで 1 組**。
`notebooks` 側が無いとポータルのノートブック / ファイル操作が壊れる。

Storage も **blob と file の両方**が必要。Hub はファイル共有も使うため、
blob だけ張るとデータセットや prompt flow のファイル操作が失敗する。

---

## 3. ★ PE 1 個 = プライベート IP 1 個ではない (実測)

ここが一番の落とし穴。**PE は 1 リソースでも、公開サフィックスごとに
ipConfiguration が分かれて別々のプライベート IP を持つ。**

```
pep-ais-aissbx-xxxxx          (PE 1 個 / subresource = account)
  ├─ 10.60.10.8    ais-aissbx-xxxxx.cognitiveservices.azure.com
  ├─ 10.60.10.9    ais-aissbx-xxxxx.openai.azure.com
  └─ 10.60.10.10   ais-aissbx-xxxxx.services.ai.azure.com

pep-oai-aissbx-xxxxx
  └─ 10.60.10.14   oai-aissbx-xxxxx.openai.azure.com

pep-spch-aissbx-xxxxx
  └─ 10.60.10.7    spch-aissbx-xxxxx.cognitiveservices.azure.com

pep-aif-aissbx                (Hub / subresource = amlworkspace)
  ├─ 10.60.10.11   <guid>.workspace.japaneast          → api.azureml.ms
  ├─ 10.60.10.11   <guid>.workspace.japaneast.cert     → api.azureml.ms
  ├─ 10.60.10.13   *.<guid>.inference.japaneast        → api.azureml.ms
  └─ 10.60.10.12   ml-aif-aissbx-japaneast-<guid>.japaneast → notebooks.azure.net
```

**ホスト名ごとに PE を増やすのではなく、ゾーンを増やすのが正しい対処。**
PE を 3 つ作っても解決しないし、余計な IP と課金が増えるだけ。

---

## 4. ★ `customDnsConfigs` は空になる (実測)

**DNS Zone Group を付けた PE の `customDnsConfigs` は空。**
Azure が名前解決を引き受けるため、自前 DNS 向けのヒントが不要になるから。

```bash
# Zone Group を付けていると空を返す → 「ゾーンが要らない」と誤読しやすい
az network private-endpoint show -g rg-aissbx -n pep-ais-aissbx-xxxxx \
  --query customDnsConfigs
# []
```

必要なホスト名を確認する正しい方法:

```bash
# (a) PE の NIC が公開する FQDN と IP
nic=$(az network private-endpoint show -g rg-aissbx -n pep-ais-aissbx-xxxxx \
        --query "networkInterfaces[0].id" -o tsv)
az network nic show --ids "$nic" \
  --query "ipConfigurations[].{ip:privateIPAddress, fqdns:privateLinkConnectionProperties.fqdns}" -o json

# (b) 実際に Private DNS Zone に登録された A レコード (= 閉域化できている範囲)
for z in $(az network private-dns zone list -g rg-aissbx --query "[].name" -o tsv); do
  echo "-- $z"
  az network private-dns record-set a list -g rg-aissbx -z "$z" \
    --query "[].{n:name, ip:aRecords[0].ipv4Address}" -o tsv
done
```

Terraform では `azurerm_private_endpoint.private_dns_zone_configs[].record_sets[]` に
`fqdn` と `ip_addresses` が入る。本構成の `outputs.tf` の
`cognitive_accounts[].private_endpoint_records` がこれを出している。

### 実際の登録内容 (本構成)

```
privatelink.api.azureml.ms
     <guid>.workspace.japaneast.cert          10.60.10.11
     *.<guid>.inference.japaneast             10.60.10.13
     <guid>.workspace.japaneast               10.60.10.11
privatelink.blob.core.windows.net
     staissbxhubxxxxx                         10.60.10.5
privatelink.cognitiveservices.azure.com
     ais-aissbx-xxxxx                         10.60.10.8
     spch-aissbx-xxxxx                        10.60.10.7
privatelink.file.core.windows.net
     staissbxhubxxxxx                         10.60.10.6
privatelink.notebooks.azure.net
     ml-aif-aissbx-japaneast-<guid>.japaneast 10.60.10.12
privatelink.openai.azure.com
     ais-aissbx-xxxxx                         10.60.10.9
     oai-aissbx-xxxxx                         10.60.10.14
privatelink.services.ai.azure.com
     ais-aissbx-xxxxx                         10.60.10.10
privatelink.vaultcore.azure.net
     kv-aissbx-xxxxx                          10.60.10.4
```

複数の Cognitive アカウントが同じゾーンを共有するのは正常
(`cognitiveservices` に ais と spch の 2 レコード)。
アカウント名がグローバル一意なのでレコード名は衝突しない。

---

## 5. ★ `privatelink` 付きの内部名を叩いてはいけない

A レコードの FQDN は `<name>.privatelink.<suffix>` という**内部名**。

```
ais-aissbx-xxxxx.privatelink.openai.azure.com   ← これは内部名。呼んではいけない
ais-aissbx-xxxxx.openai.azure.com               ← SDK に渡すのはこちら
```

> 出典: [Configure Virtual Networks for Foundry Tools](https://learn.microsoft.com/azure/ai-services/cognitive-services-virtual-networks)
>
> "Requests from clients to the private endpoint MUST specify the custom subdomain
> of your Foundry Tools resource as the endpoint base URL.
> **Do NOT call the internal URL `*.privatelink.openai.azure.com`** which is part
> of the intermediary CNAME resolution internal to Azure."

実際に内部名を curl すると TLS 証明書の SAN に無いため接続自体が失敗する
(`HTTP 000`)。検証スクリプトを書く際にここで引っかかった。

---

## 6. リージョン共通ホストはゾーンに載らない (実測)

Hub 関連で踏んだもの。**ゾーンに載るのは workspace 固有ホストだけ**で、
リージョン共通ホストは VNet 内でも公開 IP に解決される。

probe VM (VNet 内) からの `getent hosts`:

| ホスト名 | 解決結果 |
|---|---|
| `<guid>.workspace.japaneast.api.azureml.ms` | **10.60.10.11** (Private) |
| `ml-aif-aissbx-japaneast-<guid>.japaneast.notebooks.azure.net` | **10.60.10.12** (Private) |
| `japaneast.api.azureml.ms` | **公開 IP** |

リージョン共通ホストを叩く実装は閉域経路を通らない。
「VNet 内なのに公開 IP に解決される」と見えたら、まずホスト名の粒度を疑うこと。

---

## 7. VNet リンク — peering だけでは伝播しない

ゾーンを作るだけでは足りない。**呼び出し元の VNet にリンクが必要。**

```hcl
# locals.tf
private_dns_zone_vnet_links = {
  main = azurerm_virtual_network.this.id
  # AKS 等が別 VNet にあるなら、peering に加えてここにも足す
  # aks = data.azurerm_virtual_network.aks.id
}
```

**VNet peering は名前解決を伝播しない。** peering だけ張って
「疎通するはず」と思い込むと、その VNet からは公開 IP に解決され続ける。

---

## 8. 設計上の判断 — ゾーンを一元管理にした理由

同一 RG 内で同名の Private DNS Zone は 1 つしか作れない。

先行検証 `ai/ai_foundry` は「1 つ目のモジュールがゾーンを作り、
2 つ目以降は `create_private_dns_zone = false` + `private_dns_zone_ids` で再利用」
という方式だった。制約への対処としては正しいが、
**モジュール間に「どっちが先に作るか」の暗黙の順序**が生まれる。

本構成ではゾーンを**共有リソースとしてルートの `dns.tf` で一元的に作り**、
各モジュールには ID だけを配る。

```hcl
# main.tf — モジュールへは「使うゾーンの ID」だけを渡す
private_dns_zone_ids = {
  for key in each.value.dns_zone_keys : key => azurerm_private_dns_zone.this[key].id
}
```

ゾーンは VNet 単位で共有される性質のリソースなので、こちらのほうが素直。

---

## 9. 確認コマンド

```bash
# ゾーン一覧
terraform output private_dns_zones

# PE が登録した A レコード (FQDN => プライベート IP)
terraform output -json cognitive_accounts | python3 -m json.tool

# VNet 内から実際に引けるか (これが最終判定)
./verify.sh
```
