# 実測結果

- 実施日: 2026-09-15
- リージョン: japaneast
- Terraform 1.15.5 / azurerm 4.76.0
- 設定: `ai_network_mode = "private"` / `enable_foundry_hub = true` / `hub_dependencies_private = true`

作成リソース 50 件。apply 後の `terraform plan` は **`No changes`** (ドリフトなし)。

---

## 0. 実測値ひとめくり

| # | 検証項目 | 結果 | 詳細 |
|---|---|---|---|
| 1 | VNet 内からの名前解決 | **PE のプライベート IP** (`10.60.10.x`) | §1 |
| 2 | VNet 外からの名前解決 | 公開 IP (正常。遮断とは無関係) | §2 |
| 3 | VNet 内からのデータ面 API | **200** (推論成功) | §1 |
| 4 | VNet 外からのデータ面 API | **403** `Public access is disabled` | §1 |
| 5 | ルートパス `/` (VNet 外) | **200** ← **判定に使えない** | §2 |
| 6 | ARM (コントロールプレーン) | **200** (VNet 内外とも) | §7 |
| 7 | Entra ID (キーレス) 認証 | **200** (PE 経由) | §1 |
| 8 | `kind=AIServices` の PE の IP 数 | **3 個** (サフィックスごと) | §3 |
| 9 | `kind=SpeechServices` の PE の IP 数 | 1 個 | §3 |
| 10 | v1 Hub の PE の IP 数 | 3 個 / 2 ゾーン | §3 |
| 11 | DNS Zone Group 付き PE の `customDnsConfigs` | **空** | §4 |
| 12 | private Storage/KV での Hub 作成 | **成功** (1 分 15 秒) | §5 |
| 13 | `managed_network` 無しでの Hub 作成 | **成功** ← 初版の記述を訂正 | §5.1 |
| 14 | `managed_network` の provisioning 状態 | **未プロビジョニング** (`status` = null / rules は `Inactive`) | §5.1 |
| 15 | Key Vault の Secret (connection ゼロ) | **3 本存在** (既定 datastore の SAS) | §6 |
| 16 | VNet 外からのモデルデプロイ作成 | **成功** (ARM 操作のため) | §7 |
| 17 | v2 プロジェクトの自動生成 | **されなかった** (`projects` は空) | §8 |
| 18 | Foundry API のトークン audience | `https://ai.azure.com` 必須。違うと **401** | §9 |
| 19 | リージョン共通ホスト (`japaneast.api.azureml.ms`) | VNet 内でも**公開 IP** に解決 | §10 |
| 20 | `ai.azure.com` 自体 | Private Link 対象外の公開サイト (Front Door) | §11 |
| 21 | v2 `network_injection` での作成 | **成功** (5 分 35 秒) | §14 |
| 22 | injection が作るもの | **あなたの VNet** に `legionservicelink` | §14 |
| 23 | v1 `managed_network` が作るもの | **あなたの VNet には何も作らない** | §14 |
| 24 | v1 Hub のデータ面 (`/datastores`) | 内外とも 403。切り分け**未達** | §10 |
| 25 | Agent の実行 | **未検証** (BYO 3 点セット未構築) | §14 |
| 26 | injection 付きアカウントの destroy | **409 で停止。**13 分経っても `Deleting` | §14 |
| 27 | 409 後に再実行した destroy | 成功。ただし **purge が走らず論理削除の残骸が残った** | §14 |

---

## 1. 到達性の全体像

| | VNet 内 (probe VM) | VNet 外 (実行端末) |
|---|---|---|
| 名前解決 | **PE のプライベート IP** (`10.60.10.x`) | 公開 IP (`20.x.x.x`) |
| ルートパス `/` | HTTP 200 | **HTTP 200** ← 判定に使えない |
| データ面 API (chat/completions) | **200** (推論成功) | **403** |
| データ面 API (speechtotext/v3.1) | **200** | **403** |
| Foundry プロジェクト API | **200** | **403** |
| ARM (コントロールプレーン) | 200 | **200** ← 閉域化の影響を受けない |

VNet 外の 403 レスポンス:

```json
{"error":{"code":"403","message":"Public access is disabled. Please configure private endpoint."}}
```

Entra ID 認証 (VM のマネージド ID + `Cognitive Services User`) でも PE 経由で 200。
**閉域化とキーレス認証は問題なく両立する。**

---

## 2. ★ ルートパス `/` は public 無効でも 200 を返す

**遮断の判定にまったく使えない。** 最初これで誤判定しかけた。

```
VNet 外から:
  https://oai-aissbx-xxxxx.openai.azure.com/                      HTTP 200  ← 閉じているのに 200
  https://oai-.../openai/deployments/<dep>/chat/completions        HTTP 403  ← これが真実
```

**必ず実際のデータ面 API を叩き、`403 "Public access is disabled"` が出るかで判定する。**
`verify.sh` は両方を並べて表示するようにしてある。

同様に、**公開 IP に解決されること自体も異常ではない。**

> 出典: [Azure Private Endpoint private DNS zone values](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)
>
> "The CNAME chain in the public `privatelink.<service>.<region>.<suffix>` zone is
> **deliberately resolvable from anywhere on the internet**... A successful public
> DNS lookup confirms only that a resource with that exact name exists...
> It doesn't confirm that a private endpoint is attached... **Resource existence is
> enumerable; resource access is not.**"

### 判定表

| 観測 | 意味 |
|---|---|
| VNet 内の名前解決が `10.60.10.x` | **OK。** Private 経路が成立 |
| VNet 内の名前解決が公開 IP | ゾーン不足 / VNet リンク漏れ / ホスト名の粒度違い |
| データ面 API が **403** + `Public access is disabled` | **ネットワーク遮断** (期待どおり) |
| データ面 API が **401** + `audience is incorrect` | ネットワークではなく**トークンのオーディエンス違い** |
| データ面 API が 401 / 404 (その他) | ネットワークは通ってアプリ層まで到達 (ネットワークは無罪) |
| ルートパス `/` が 200 | **何も意味しない** |

---

## 3. ★ PE 1 個 = IP 1 個ではない

`kind = AIServices` の PE 1 個が、公開サフィックスごとに別々のプライベート IP を持つ。

```
pep-ais-aissbx-xxxxx  (PE 1 個 / subresource = account)
  ├─ 10.60.10.8    ...cognitiveservices.azure.com
  ├─ 10.60.10.9    ...openai.azure.com
  └─ 10.60.10.10   ...services.ai.azure.com
```

Speech は 1 つだけ (`cognitiveservices`)。Hub は 3 IP / 2 ゾーン。
詳細は [01-private-dns-zones.md](01-private-dns-zones.md) §3。

---

## 4. ★ `customDnsConfigs` は空になる

DNS Zone Group を付けた PE では `customDnsConfigs` が空を返す。
「ゾーンが要らない」と誤読しやすい。
必要なホスト名は NIC の `privateLinkConnectionProperties.fqdns`、
または登録済み A レコードで確認する。
詳細は [01-private-dns-zones.md](01-private-dns-zones.md) §4。

---

## 5. ★ Hub は private Storage / private Key Vault でも作成できた

| リソース | 設定 |
|---|---|
| Storage | `publicNetworkAccess = Disabled` + `bypass = AzureServices` + blob/file の PE |
| Key Vault | `publicNetworkAccess = Disabled` + `bypass = AzureServices` + vault の PE |
| Hub | `publicNetworkAccess = Disabled` + amlworkspace の PE |

```
azurerm_ai_foundry.this[0]: Creation complete after 1m15s
```

### 5.1 ★ 訂正 — managed_network は Hub 作成の条件ではなかった

**初版では「`managed_network` + `bypass = AzureServices` をセットにすれば Hub 作成が通る」
と書いたが、因果を検証していなかった。A/B テストの結果、誤りだった。**

同じ private Storage / private Key Vault に対し、
`managedNetwork.isolationMode = "Disabled"` (マネージド VNet なし) の Hub を作成:

```json
{ "mn": "Disabled", "pna": "Disabled", "prov": "Succeeded" }
```

```bash
$ az rest ... /outboundRules
{ "value": [] }          # マネージド PE は 1 本も作られない
```

**managed_network なしでも作成できる。**
Hub 作成は ARM (コントロールプレーン) 操作で Storage のデータ面に触らないため。

さらに、本構成 (`AllowInternetOutbound`) 側のマネージド VNet も
**実際には構築されていなかった**:

```bash
$ az rest ... --query "properties.managedNetwork.status"
(null)                    # 未プロビジョニング

$ az rest ... /outboundRules
Inactive   PrivateEndpoint  Required   staissbxhubxxxxx/blob
Inactive   PrivateEndpoint  Required   staissbxhubxxxxx/file
Inactive   PrivateEndpoint  Required   kv-aissbx-xxxxx/vault
Inactive   PrivateEndpoint  Required   aif-aissbx/amlworkspace
```

`isolation_mode` を設定しても、マネージド VNet は初回の計算リソース作成時まで
構築されない (遅延プロビジョニング)。
つまり **Hub 作成時点では managed_network は一切働いていなかった。**

`managed_network` が効くのは作成時ではなく**実行時** (prompt flow / 評価 / compute から
閉じた Storage のデータ面を叩くとき)。**本検証ではそこまで実行していない [未検証]。**

詳細は [07-managed-network.md](07-managed-network.md)。

---

## 6. ★ Key Vault の Secret は Hub 作成時点で自動生成される

**connection を 1 つも作っていないのに、Hub 作成時点で 3 本入っていた。**

| Secret 名 | contentType | 中身 |
|---|---|---|
| `<guid>-workspaceblobstore00010101000000000` | `application/vnd.ms-StorageAccountAccessKey` | Storage の **SAS** (`sv=2025-...`, 108 文字) |
| `<guid>-workspaceartifactstore00010101000000000` | 同上 | 同上 |
| `<guid>-workspaceworkingdirectory00010101000000000` | 同上 | 同上 |

Hub の**既定 datastore 3 つ**に対応。値は生のアカウントキーではなく SAS
(Storage のアカウントキー先頭 `0p7lnqk2` とは一致しない)。

VNet 内から PE 経由 + Entra ID 認証 (`Key Vault Secrets User`) で読めることも確認済み。
詳細は [04-storage-and-keyvault.md](04-storage-and-keyvault.md) §3。

---

## 7. ★ コントロールプレーンは閉域化の影響を受けない

VNet 外の実行端末から、すべて **200**:

| 操作 | HTTP |
|---|---|
| ARM: AIServices アカウント取得 | 200 |
| ARM: モデルデプロイ一覧 | 200 |
| ARM: v2 プロジェクト一覧 | 200 |
| ARM: Hub (AML workspace) 取得 | 200 |

さらに、**VNet 外の端末から public 無効のアカウントにモデルをデプロイできた**:

```
azurerm_cognitive_deployment.aiservices[0]: Creation complete after 15s
azurerm_cognitive_deployment.openai[0]:     Creation complete
```

これが「Azure ポータルからならモデルデプロイできる」ことの根拠。
詳細は [03-portal-and-gui.md](03-portal-and-gui.md)。

---

## 8. ★ v2 プロジェクトは自動生成されなかった

`allowProjectManagement = true` にもかかわらず:

```json
{ "apm": true, "ap": null }          // associatedProjects が null
{ "value": [] }                      // /projects が空
```

先行検証 `ai/ai_foundry` (public **有効**で作成) では、入れ子 v2 プロジェクトが
**アカウント作成と同時刻に自動生成**されていた。**挙動が違う。**
public 無効で作ったことが効いているのか、Azure 側の仕様変更かは切り分けていない **[未確定]**。

対処として `azurerm_cognitive_account_project` で明示的に作成した。
Terraform 管理下に入るため、`ai/ai_foundry` で踏んだ
「入れ子プロジェクトが destroy を 409 で止める」問題も起きない。

```
$ terraform output aiservices_project
{
  "endpoints": { "AI Foundry API": "https://ais-aissbx-xxxxx.services.ai.azure.com/api/projects/proj-aissbx" },
  "name": "proj-aissbx"
}
```

---

## 9. ★ トークンのオーディエンスで 401 と 403 が入れ替わる

Foundry のプロジェクト API (`/api/projects/<proj>/...`) は
`https://ai.azure.com` のトークンを要求する。

VNet 外から同じ URL を叩いた結果:

| トークンの `--resource` | HTTP | メッセージ |
|---|---|---|
| `https://cognitiveservices.azure.com` | **401** | `audience is incorrect (https://ai.azure.com)` |
| `https://management.azure.com` | **401** | 同上 |
| **`https://ai.azure.com`** | **403** | **`Public access is disabled. Please configure private endpoint.`** |

**401 が出たら「閉域化が効いた」ではなく「トークンが違う」を先に疑うこと。**
ネットワーク遮断は必ず 403 + `Public access is disabled`。

---

## 10. ★ リージョン共通ホストは閉域経路を通らない

probe VM (VNet 内) からの名前解決:

| ホスト名 | 解決結果 |
|---|---|
| `<guid>.workspace.japaneast.api.azureml.ms` | **10.60.10.11** (Private) |
| `ml-aif-aissbx-japaneast-<guid>.japaneast.notebooks.azure.net` | **10.60.10.12** (Private) |
| `japaneast.api.azureml.ms` | **公開 IP** |

ゾーンに載るのは **workspace 固有ホストだけ**。
リージョン共通ホストを叩く実装は VNet 内にいても閉域経路を通らない。

> なお Hub (v1) のデータ面 (`/rp/workspaces/.../datastores`) は
> VNet 内外とも 403 のままで、ネットワークか RBAC かの切り分けができていない **[未確定]**。
> 本検証の主対象は v2 (kind = AIServices) 側であり、そちらは 403 → 200 で確認済み。

---

## 11. ポータルの Web サイト自体は公開インターネット上にある

`ai.azure.com` は Private Link 対象ではない (Front Door 上の公開 Web サイト)。

```
ai.azure.com -> 150.171.110.137
```

probe VM からの到達性:

| URL | HTTP |
|---|---|
| `https://ai.azure.com` | 200 |
| `https://ml.azure.com` | 200 |
| `https://login.microsoftonline.com` | 200 |
| `https://speech.microsoft.com` | 200 (ページは開くが機能しない) |

**完全にインターネット遮断された VM ではポータルのページ自体が開けない。**
詳細は [03-portal-and-gui.md](03-portal-and-gui.md) §3。

---

## 12. apply 中に踏んだエラー

| 症状 | 原因 / 対処 |
|---|---|
| `ServiceModelDeprecating` で 400 | `gpt-4o-mini` (2024-07-18) は廃止予定で新規デプロイ不可。`gpt-5.4-mini` (2026-03-17) に変更して成功。`az cognitiveservices account list-models` で GA の版を確認する |
| PE が `AccountProvisioningStateInvalid` で 400 | アカウントが `Accepted` 状態のときの一過性エラー。再実行で成功 |
| `Missing required argument: principal_id` | VM に後からマネージド ID を足すと、同じ plan 内の `azurerm_role_assignment` が `identity[0]` を解決できない。`terraform apply -target=azurerm_linux_virtual_machine.jumpbox` を先に 1 回流す |
| `could not find role 'Azure AI User'` | **そのロールは存在しない** (2026-09 時点)。Foundry 系は `Azure AI Developer` / `Azure AI Administrator` |
| 内部名を curl して `HTTP 000` | `*.privatelink.*` は TLS 証明書の SAN に無い。公開名を使う |

---

## 14. ★ v2 virtual network injection の実測

| 項目 | 結果 |
|---|---|
| `azurerm_cognitive_account` の `network_injection` ブロック | ✅ azurerm 4.76.0 に存在 (`scenario` / `subnet_id`) |
| 委任サブネット (`Microsoft.App/environments`, `10.60.40.0/24`) での作成 | **✅ 成功** |
| 作成時間 | **5 分 35 秒** (通常のアカウントは数秒) |
| ARM プロパティ | `networkInjections[].useMicrosoftManagedNetwork = false` |
| サブネットへの影響 | `serviceAssociationLinks: legionservicelink` (`Microsoft.App/environments`) |
| 受信 PE との併用 | ✅ `public_network_access_enabled = false` + PE と同時に成立 |
| サブネットの IP 消費 (作成直後) | **0 / 251**。実行時にオンデマンドと推測 **[未検証]** |
| v2 プロジェクトの自動生成 | ❌ されない |
| **v1 `managed_network` が自分の VNet に作るもの** | **なし** (Microsoft 側に作られる) |
| Agent の実行 | **[未検証]** BYO の Storage/Cosmos/AI Search が別途必要 |
| **削除の所要時間** | **13 分経過時点でまだ `Deleting`。**destroy が 409 `provisioning state is not terminal` で一度停止する |
| **409 後の再実行** | destroy 自体は成功するが、`purge_soft_delete_on_destroy = true` が働かず**論理削除の残骸が残る**。手動 purge が必要 |

```json
"networkInjections": [{
  "scenario": "agent",
  "subnetArmId": ".../virtualNetworks/vnet-aissbx/subnets/snet-agent",
  "useMicrosoftManagedNetwork": false
}]
```

詳細は [08-v1-vs-v2.md](08-v1-vs-v2.md) §4。

---

## 15. 再現方法

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id を埋める
terraform init && terraform apply
./verify.sh                                   # VNet 内 / 外を並べて確認
```

`verify.sh` が確認するもの:

1. VNet 内から PE のプライベート IP に解決されるか
2. VNet 内からデータ面 API が 200 か (Entra ID 認証)
3. VNet 外からデータ面 API が 403 `Public access is disabled` か
