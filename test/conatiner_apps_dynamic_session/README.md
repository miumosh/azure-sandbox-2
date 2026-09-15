# AKS (Private) から Container Apps Dynamic Sessions を利用する

調査日: 2026-07-17
リソース作成を伴う検証: `japaneast` / サービスタグ実測: `japaneast`, `eastasia`, `eastus`, `westus2`, `westeurope`
検証済み API バージョン: `2026-01-01`, `2026-03-02-preview`, `2024-10-02-preview`, `2024-02-02-preview`

本ドキュメントの主張は原則すべて **Azure の API を実際に叩いた実測**に基づく。ドキュメント URL は補足として併記する。

---

## 1. 結論（TL;DR）

**「Dynamic Sessions は Public のみ」は半分正しく、半分誤り。プールの種類で答えが変わる。**

| プール種別 | 管理エンドポイント | Private 化 | AKS からの経路 |
|---|---|---|---|
| **Code interpreter**<br>(`PythonLTS` / `NodeLTS` / `Shell`) | `https://<region>.dynamicsessions.io/...` | **不可**<br>PE / VNet / publicNetworkAccess すべて非存在 | **Public 経由必須**<br>→ Azure Firewall で許可 |
| **Custom container**<br>(`CustomContainer`) | `https://<pool>.<envid>.<region>.azurecontainerapps.io` | **可能**<br>internal 環境 + Private Endpoint | **完全 Private**<br>→ Firewall 許可不要 |

Custom container プールは Container Apps **環境 (`Microsoft.App/managedEnvironments`) 配下**に作られ、環境は PE をサポートするため、管理エンドポイントごと Private 化できる。Code interpreter プールは環境を持たない（`environmentId: null`）ため、この経路が使えない。

要件が「Private 通信」なら **Custom container プールが唯一の解**。Python 実行が目的なら Python 入りイメージを自前で用意することで Code interpreter 相当を Private で再現できる。

> ⚠️ **`poolManagementType: Dynamic` は判断材料にならない**（両種別とも `Dynamic`）。見るべきは **`containerType`** と **`environmentId`**。判定手順は §2.5。

---

## 2. できること / できないこと

### ❌ できないこと

| 項目 | 実測による根拠 |
|---|---|
| `Microsoft.App/sessionPools` への Private Endpoint | Network RP が**許可リストごとエラーで返す**（後述 3.1）。`Microsoft.App/managedEnvironments` は含まれるが `sessionPools` は含まれない |
| `dynamicsessions.io` の Private DNS ゾーン | `privatelink.dynamicsessions.io` は非存在。`<region>.dynamicsessions.io` は Public IP に A レコード直返し（CNAME チェーンなし） |
| sessionPools の `publicNetworkAccess` による ingress 制限 | PATCH しても**黙って無視**され GET に現れない＝プロパティ自体が存在しない |
| sessionPools の子リソースによる PE 接続管理 | `sessionPools` の子リソース型は**ゼロ**。`containerApps` / `managedEnvironments` には `privateEndpointConnectionProxies` があるが sessionPools には無い |
| 管理エンドポイントの IP 制限 / ファイアウォール | 該当プロパティなし。**アクセス制御は Entra ID + RBAC のみ**（§6.1） |
| Code interpreter プールの VNet 配置 | `environmentId: null` 固定。VNet 関連の引数が CLI/ARM に存在しない |
| 送信元 IP ベースでの「セッションからの通信」の識別 | セッションの送信元 IP は Microsoft 管理の共有 IP。特定・固定できないため許可リストが組めない（§7.3） |

### ✅ できること

| 項目 | 実測による根拠 |
|---|---|
| **Custom container プールの完全 Private 化** | internal 環境 + PE で `*.{envid}.japaneast.azurecontainerapps.io → 10.10.2.4` に解決（後述 3.5） |
| Code interpreter を **サービスタグで狭く許可** | 管理エンドポイント IP は `ContainerAppsManagement.<Region>` に含まれる（後述 3.2）。**専用タグが無いという理解は誤り** |
| Entra ID 認証によるアクセス制御 | 認証なし → `HTTP 401`。RBAC ロール `Azure ContainerApps Session Executor` |
| **セッション → AKS を原理的に遮断** | `sessionNetworkConfiguration.status: EgressDisabled`（既定）でセッションは一切 outbound できない（§7.2） |
| MCP サーバ経路を閉じる | `mcpServerSettings` は**既定で有効・API キー未無効化**。ARM で明示的に閉じられる（§6.2） |
| セッション outbound の VNet 注入 | `sessionNetworkConfiguration.outboundVnetSubnetId` が実 API レスポンスに存在。ただし**未ドキュメント・設定可否は未検証**（§7.2） |

---

## 2.5 判定方法 — どのフィールドを見るか

### `poolManagementType` は判断材料にならない

今回作成した 2 つのプールの**実測レスポンス**:

| | code interpreter (`testpool`) | custom container (`pool-custom`) |
|---|---|---|
| `poolManagementType` | **`Dynamic`** | **`Dynamic`** |
| `containerType` | `PythonLTS` | `CustomContainer` |
| `environmentId` | `null` | `/...(env-priv)` |
| `poolManagementEndpoint` | `japaneast.dynamicsessions.io/...` | `pool-custom.<envid>.japaneast.azurecontainerapps.io` |
| Private 化 | **不可** | **可能**（PE 実証済み） |

**両方とも `Dynamic`。にもかかわらず一方は Public 固定、もう一方は Private 化できた。**
→ `poolManagementType` は Private 可否と無関係。

### 決定要因は `containerType`（と、それに伴う `environmentId` の有無）

| `containerType` | `environmentId` | エンドポイント | Private 化 |
|---|---|---|---|
| `PythonLTS` / `NodeLTS` / `Shell` | 指定不可・`null` 固定 | `<region>.dynamicsessions.io` | **不可** |
| `CustomContainer` | **必須** | `<pool>.<envid>.<region>.azurecontainerapps.io` | **可能**（環境の PE） |

これは **Microsoft 公式の REST API 仕様のサンプルでも裏付けられる**
（[Create Or Update, api-version 2026-01-01](https://learn.microsoft.com/en-us/rest/api/resource-manager/containerapps/container-apps-session-pools/create-or-update)）。
どちらのサンプルも `poolManagementType: "Dynamic"` だが、レスポンスのエンドポイントが割れている:

```jsonc
// 仕様サンプル "Create or Update Session Pool with MCP server"
// containerType: "Shell" / environmentId なし
"poolManagementEndpoint": "https://eastus.dynamicsessions.io/subscriptions/.../sessionPools/testsessionpool"

// 仕様サンプル "Create or Update Session Pool with lifecycle type Timed"
// containerType: "CustomContainer" / environmentId あり
"poolManagementEndpoint": "https://testsessionpool.agreeableriver-xxxxxxxx.eastus.azurecontainerapps.io"
```

### 手元のプールを 1 コマンドで判定する

```bash
az containerapp sessionpool show -n <POOL> -g <RG> \
  --query "{containerType:properties.containerType, envId:properties.environmentId, ep:properties.poolManagementEndpoint}"
```

**`environmentId` が `null` → Public 固定。PE は張れない。**

### ARM テンプレートの判定例

```jsonc
{
  "type": "Microsoft.App/sessionPools",
  "apiVersion": "2026-01-01",
  "name": "test-pool",
  "location": "East Asia",
  "properties": {
    "poolManagementType": "Dynamic",     // ← 判断材料にならない
    "containerType": "PythonLTS",        // ← これが決定的：code interpreter
    "scaleConfiguration": { "maxConcurrentSessions": 600 },
    "sessionNetworkConfiguration": { "status": "EgressDisabled" }
    // environmentId なし（PythonLTS では指定不可）
  }
}
```

**判定: Public 固定。PE 不可。**
エンドポイントは `https://eastasia.dynamicsessions.io/subscriptions/<SUB>/resourceGroups/<RG>/sessionPools/test-pool` となり、
`eastasia.dynamicsessions.io` (`20.205.49.35`) への Public 通信が必須（§3.2 / §5 の Firewall 許可が要る）。

Private 化するには `containerType` を `CustomContainer` に変え、`environmentId` に internal 環境を指定する必要がある
（＝ ACA 環境の新規作成 + イメージ用意を伴うテンプレートの作り直し）。

補足:
- `maxConcurrentSessions: 600` は**上限値ちょうど**（許容範囲は 1〜600）
- `sessionNetworkConfiguration.status: "EgressDisabled"` は既定どおり。これは**サンドボックス内コードの外向き通信**の話で、AKS → プールの経路とは無関係（§3.6）

### `poolManagementType` の取りうる値（参考）

REST API 仕様の `PoolManagementType` enum は **`Manual` / `Dynamic`** の 2 値。
ただし **`az containerapp sessionpool create` にこれを指定する引数は存在しない**（実測: `--container-type` はあるが `--pool-management-type` 系は無し）ため、
CLI 経由では常に `Dynamic` になる。`Manual` の使い方を説明した公式ドキュメントも見当たらず、**実質 `Dynamic` 一択**。

---

## 3. 検証の証跡

### 3.1 PE 非対応の証明 — プラットフォーム自身の許可リスト

ドキュメントの表に「載っていない」ではなく、**PE 作成時に実際に評価される許可リスト**で拒否される。

```bash
az network private-endpoint create -g rg-dynsess-test -n pe-testpool -l japaneast \
  --vnet-name vnet-test --subnet snet-pe \
  --private-connection-resource-id ".../Microsoft.App/sessionPools/testpool" \
  --group-id sessionPools --connection-name conn-testpool
```

```
ERROR: (InvalidPrivateLinkServiceIdType) Private link service Id
  .../Microsoft.App/sessionPools/testpool has an invalid resource type.
Permitted type(s): Microsoft.DocumentDB/databaseAccounts, ...,
  Microsoft.App/managedEnvironments, ...          ← 環境は有る
                                                   ← sessionPools は無い
```

補強証拠 — `privateLinkResources` サブルートの有無の差:

```bash
# sessionPools（リソースは実在する）→ 素の Not Found ＝ ルート自体が非存在
az rest --method get --url ".../sessionPools/testpool/privateLinkResources?api-version=2026-01-01"
#=> ERROR: Not Found

# managedEnvironments（存在しない名前を指定）→ ARM 構造化エラー ＝ ルートは存在する
az rest --method get --url ".../managedEnvironments/doesnotexist/privateLinkResources?api-version=2026-01-01"
#=> ERROR: Not Found({"error":{"code":"ResourceNotFound", ...}})

# 対照実験: プール本体は同 api-version で正常に GET できる
az rest --method get --url ".../sessionPools/testpool?api-version=2026-01-01"
#=> {"name": "testpool", "state": "Succeeded"}
```

`publicNetworkAccess` が存在しないことの確認:

```bash
az rest --method patch --url ".../sessionPools/testpool?api-version=2026-03-02-preview" \
  --body '{"properties":{"publicNetworkAccess":"Disabled"}}'
#=> 200 だが、レスポンスにも後続の GET にも publicNetworkAccess は現れない（ARM が未知プロパティを黙殺）
```

### 3.2 サービスタグ — `ContainerAppsManagement` に含まれる

```bash
dig +short japaneast.dynamicsessions.io   #=> 20.210.69.67
az network list-service-tags --location japaneast   # を IP で逆引き
```

| リージョン | 管理エンドポイント IP | 該当サービスタグ | プレフィックス |
|---|---|---|---|
| japaneast | 20.210.69.67 | `ContainerAppsManagement.JapanEast` | 20.210.69.64/28 |
| **eastasia** | **20.205.49.35** | **`ContainerAppsManagement.EastAsia`** | **20.205.49.32/28** |
| eastus | 20.88.159.199 | `ContainerAppsManagement.EastUS` | 20.88.159.192/28 |
| westus2 | 20.125.1.115 | `ContainerAppsManagement.WestUS2` | 20.125.1.112/28 |
| westeurope | 20.105.243.195 | `ContainerAppsManagement.WestEurope` | 20.105.243.192/28 |

5 リージョンとも規則的に `/28` に収まる（偶然ではない）。各タグの全範囲も非常に狭い:

```
ContainerAppsManagement.JapanEast:
  20.89.184.245/32, 20.210.69.64/28, 20.210.80.170/32, 2603:1040:407::690/124
ContainerAppsManagement.EastAsia:
  20.205.49.32/28, 20.239.5.125/32, 20.239.5.160/32, 2603:1040:207:2::2b0/124
```

他リージョンを使う場合の確認手順:

```bash
dig +short <REGION>.dynamicsessions.io
az network list-service-tags --location <REGION>   # 上記 IP を ContainerAppsManagement.<Region> に逆引き
```

> ⚠️ このタグは Container Apps の管理プレーン全体を指し、Dynamic Sessions 専用ではない（=わずかに広い）。厳密に絞るなら FQDN ルールを併用する（§5）。

### 3.3 疎通実測（curl）

```bash
EP="https://japaneast.dynamicsessions.io/subscriptions/<SUB>/resourceGroups/rg-dynsess-test/sessionPools/testpool"

# 認証なし
curl -s -o /dev/null -w "%{http_code} %{remote_ip}" "$EP/python/execute?api-version=2024-02-02-preview&identifier=test1"
#=> 401 20.210.69.67

# audience = https://management.azure.com  → 効かない
TOKEN=$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
#=> HTTP 401

# audience = https://dynamicsessions.io  → 成功
TOKEN=$(az account get-access-token --resource https://dynamicsessions.io --query accessToken -o tsv)
curl -X POST "$EP/code/execute?api-version=2024-02-02-preview&identifier=test1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"properties":{"codeInputType":"inline","executionType":"synchronous","code":"print(6*7)"}}'
#=> 200
#=> {"properties":{"status":"Success","stdout":"42\n","executionTimeInMilliseconds":6}}
```

> ⚠️ **トークンの `aud` は `https://dynamicsessions.io`。`management.azure.com` では 401**。ハマりやすい。
> ドキュメントでも明記: 「the token needs to contain an audience (`aud`) claim with the value `https://dynamicsessions.io`」

### 3.4 RBAC

`dataActions` を持つ実効ロールは 1 つだけ:

```bash
az role definition list --query "[?roleName=='Azure ContainerApps Session Executor'].permissions[0].dataActions"
```
```json
[ "Microsoft.App/sessionPools/*/read",
  "Microsoft.App/sessionPools/interpreters/execute/action",
  "Microsoft.App/sessionPools/interpreters/read",
  "Microsoft.App/sessionPools/executions/*",
  "Microsoft.App/sessionPools/files/*" ]
```

```bash
az role assignment create \
  --role "Azure ContainerApps Session Executor" \
  --assignee <PRINCIPAL_ID> \
  --scope <SESSION_POOL_RESOURCE_ID>
```

### 3.5 Custom container プールの Private 化（実証済み）

```bash
# 1. delegation 必須（無いと ManagedEnvironmentSubnetDelegationError）
az network vnet subnet update -g $RG --vnet-name vnet-ca -n snet-infra \
  --delegations Microsoft.App/environments

# 2. internal + workload profiles 環境
az containerapp env create -n env-priv -g $RG -l japaneast \
  --enable-workload-profiles true \
  --infrastructure-subnet-resource-id "$SNET" \
  --internal-only true
#=> staticIp: 10.10.0.130 / internal: true / publicNetworkAccess: Disabled

# 3. custom container セッションプール
az containerapp sessionpool create -n pool-custom -g $RG --location japaneast \
  --environment env-priv --container-type CustomContainer \
  --image mcr.microsoft.com/k8se/quickstart:latest \
  --cpu 0.25 --memory 0.5Gi --target-port 80 \
  --cooldown-period 300 --max-sessions 3 --ready-sessions 1 \
  --network-status EgressDisabled
#=> poolManagementEndpoint: https://pool-custom.purplebush-xxxxxxxx.japaneast.azurecontainerapps.io
#=>                         ↑ dynamicsessions.io ではない
```

**Public から到達不能であることの確認:**

```bash
dig +short pool-custom.purplebush-xxxxxxxx.japaneast.azurecontainerapps.io
#=> (空 — 公開 DNS に A レコードが存在しない)
curl --max-time 15 "https://pool-custom.purplebush-xxxxxxxx.japaneast.azurecontainerapps.io/"
#=> HTTP 000 | exitcode=6 (Could not resolve host)
```

**環境が PE リソースを公開していることの確認:**

```bash
az rest --method get --url "${ENVID}/privateLinkResources?api-version=2024-10-02-preview"
```
```
groupId: managedEnvironments
members: ['managedEnvironments']
zones  : ['privatelink.japaneast.azurecontainerapps.io']
```

**PE 作成成功（決定的）:**

```bash
az network private-endpoint create -g $RG -n pe-env -l japaneast \
  --vnet-name vnet-ca --subnet snet-pe \
  --private-connection-resource-id "$ENVID" \
  --group-id managedEnvironments --connection-name conn-env
```
```
PE provisioningState: Succeeded
  fqdn: *.purplebush-xxxxxxxx.japaneast.azurecontainerapps.io -> ['10.10.2.4']
  connState: {'status': 'Approved', 'description': 'Auto-approved'}
```

ワイルドカード `*` がセッションプール管理エンドポイント `pool-custom.<envid>...` を**包含する**。
→ **AKS から Private IP `10.10.2.4` 経由でセッションプールを呼べる。Firewall 許可は不要。**

> なお AKS が同一 VNet かピアリング済み VNet にある場合、`--internal-only true` による VNet 統合だけで内部 VIP (`10.10.0.130`) に到達できるため、**PE すら不要**。PE が要るのは非ピアリングの別 VNet / オンプレからの接続時。

### 3.6 セッション自身の egress（方向が逆なので混同注意）

```json
"sessionNetworkConfiguration": {
  "outboundVnetSubnetId": null,     // ← セッション → 自分の VNet へ注入できる
  "status": "EgressDisabled"        // ← 既定。インターネット遮断
}
```

これは「サンドボックス内のコード → 外」の制御であり、「AKS → セッションプール」とは**別物**。AKS 側の Firewall ルールとは無関係。サンドボックス内のコードが Private な DB 等に到達する必要がある場合に `outboundVnetSubnetId` を使う。

---

## 4. アーキテクチャ選択

### 案 A: Code interpreter + Public 経由（Firewall 許可）

```
[Private AKS] --UDR--> [Azure Firewall] --Public--> japaneast.dynamicsessions.io (20.210.69.67)
                                        --Public--> login.microsoftonline.com
```

- ✅ 構築が単純。マネージドな Python/Node 実行環境をそのまま使える
- ❌ Public 経路。宛先は `/28` まで絞れるが、インターネットには出る
- ❌ Private 化の将来対応は期待薄（プロパティすら存在しない = ロードマップ上も近くない）

### 案 B: Custom container + internal 環境（完全 Private）※要件が Private なら唯一の解

```
[Private AKS] --VNet/Peering or PE--> [internal ACA env] --> pool-custom.<envid>.japaneast.azurecontainerapps.io (10.10.x.x)
              --Firewall--> login.microsoftonline.com  ← トークン取得のみ Public
```

- ✅ 管理エンドポイントが Private IP。Public DNS に載らない
- ✅ Hyper-V 分離のサンドボックス特性は同じ
- ❌ ACA 環境 + workload profiles の運用コスト。イメージを自前で用意・保守
- ❌ Code interpreter の `/code/execute` API 等は使えず、自前コンテナが HTTP サーバを実装する必要がある
- ⚠️ **どちらの案でも `login.microsoftonline.com` への Public 通信は必須**（Entra トークン取得のため）

---

## 5. Azure Firewall ルール（案 A 用）

前提: AKS のノード/Pod サブネットに UDR で `0.0.0.0/0 → Azure Firewall Private IP` が設定済み。

以下の例は **japaneast** 前提。**East Asia** の場合は次のように読み替える（いずれも実測済み・§3.2）:

| | japaneast | eastasia |
|---|---|---|
| サービスタグ | `ContainerAppsManagement.JapanEast` | `ContainerAppsManagement.EastAsia` |
| FQDN | `japaneast.dynamicsessions.io` | `eastasia.dynamicsessions.io` |

### 5.1 ネットワークルール（推奨）

TLS/SNI 検査が不要で、宛先も `/28` 中心と狭いため最も素直。

| 項目 | 値 |
|---|---|
| Rule collection | `rcg-aks-egress` / Priority `200` / Action `Allow` |
| Rule name | `allow-dynamicsessions` |
| Source | `<AKS ノード・Pod サブネット CIDR>` |
| Protocol | `TCP` |
| Destination Type | **Service Tag** |
| Destination | `ContainerAppsManagement.JapanEast` |
| Destination Ports | `443` |

```bash
az network firewall network-rule create \
  --resource-group <FW_RG> \
  --firewall-name <FW_NAME> \
  --collection-name rcg-aks-egress \
  --name allow-dynamicsessions \
  --source-addresses <AKS_SUBNET_CIDR> \
  --protocols TCP \
  --destination-addresses ContainerAppsManagement.JapanEast \
  --destination-ports 443 \
  --priority 200 --action Allow
```

Firewall Policy を使う場合:

```bash
az network firewall policy rule-collection-group collection add-filter-collection \
  --resource-group <FW_RG> \
  --policy-name <POLICY_NAME> \
  --rule-collection-group-name DefaultNetworkRuleCollectionGroup \
  --name allow-dynamicsessions \
  --collection-priority 200 --action Allow \
  --rule-name allow-dynamicsessions --rule-type NetworkRule \
  --source-addresses <AKS_SUBNET_CIDR> \
  --ip-protocols TCP \
  --destination-addresses ContainerAppsManagement.JapanEast \
  --destination-ports 443
```

### 5.2 アプリケーションルール（FQDN で厳密に絞る場合）

サービスタグは Container Apps 管理プレーン全体を含むため、Dynamic Sessions のみに限定したい場合はこちら。Azure Firewall は SNI を見て判定するので TLS 終端は不要。

| 項目 | 値 |
|---|---|
| Rule collection | `rcg-aks-app` / Priority `210` / Action `Allow` |
| Rule name | `allow-dynamicsessions-fqdn` |
| Source | `<AKS ノード・Pod サブネット CIDR>` |
| Protocol | `https:443` |
| Target FQDNs | `japaneast.dynamicsessions.io` |

```bash
az network firewall application-rule create \
  --resource-group <FW_RG> \
  --firewall-name <FW_NAME> \
  --collection-name rcg-aks-app \
  --name allow-dynamicsessions-fqdn \
  --source-addresses <AKS_SUBNET_CIDR> \
  --protocols https=443 \
  --target-fqdns japaneast.dynamicsessions.io \
  --priority 210 --action Allow
```

> ネットワークルールとアプリケーションルールを**両方**入れると、Azure Firewall はネットワークルールを先に評価して許可・通過させるため、アプリケーションルールの FQDN 絞り込みが効かなくなる。**どちらか一方にする。**

### 5.3 Entra ID トークン取得（必須・別枠）

| 項目 | 値 |
|---|---|
| Rule name | `allow-entra-login` |
| Protocol | `https:443` |
| Target FQDNs | `login.microsoftonline.com`, `login.microsoft.com`, `login.windows.net` |

AKS の必須エグレスに含まれるため、多くの環境では**既に許可済み**。未設定の場合のみ追加。

### 5.4 追加不要なもの

- **MCP エンドポイント** (`.../sessionPools/<pool>/mcp`): 同一ホストのパス違いなので追加許可不要
- **セッション自身の egress**: `EgressEnabled` にしても Microsoft 側のネットワークから出るため、**自分の Firewall は通らない**（§3.6）
- **`management.azure.com`**: データプレーン API 呼び出しには不要（プール作成等の管理操作を AKS 内から行う場合のみ必要）

### 5.5 まとめ（最小構成）

```
[必須] ContainerAppsManagement.JapanEast : TCP/443   (Network Rule)
        または japaneast.dynamicsessions.io : https:443 (Application Rule) ※排他
[必須] login.microsoftonline.com : https:443          (Application Rule / 多くは設定済み)
```

---

## 6. Dynamic Sessions 側のインバウンド制御（＝プールに入ってくる通信）

§5 は「AKS から出ていく通信」の話。ここは逆に「プール側で入り口を絞れるか」。

### 6.1 Code interpreter プール（`dynamicsessions.io`）— ネットワーク層の制御は存在しない

| 制御手段 | 可否 | 実測による根拠 |
|---|---|---|
| Private Endpoint | ❌ | Network RP が許可リストごと拒否（§3.1） |
| `publicNetworkAccess` | ❌ | PATCH が黙殺・プロパティ非存在（§3.1） |
| IP 許可リスト / ファイアウォール | ❌ | 該当プロパティが `properties` に存在しない |
| NSG | ❌ | プールは Microsoft 管理のマルチテナント基盤上にあり、自分のサブネットに存在しない。NSG の適用対象にならない |
| サービスタグによる制限 | ❌ | §5 のサービスタグは**自分の egress を絞る**もの。相手の ingress は制御しない |

**結論: ネットワーク層の防御はゼロ。エンドポイントはインターネット上の誰からでも到達できる。**
到達したうえで認証で弾く設計であり、**Entra ID 認証が唯一の境界**（認証なし → `HTTP 401` を実測）。

したがって実質的な制御は ID 層のみ:

| 制御 | 内容 |
|---|---|
| Entra ID トークン必須 | `aud` = `https://dynamicsessions.io`。`management.azure.com` では 401（§3.3） |
| RBAC | `Azure ContainerApps Session Executor` を**プール単位のスコープ**で付与（サブスクリプション/RG スコープで広く付けない） |
| `identifier` の秘匿 | セッション識別子を知られると他人のセッションに入れる。公式ドキュメントが繰り返し警告している。暗号学的に予測不能な値を使い、URL やログに出さない |

> ⚠️ **Managed Identity には Conditional Access が適用できない**（一般論）。AKS の Workload Identity 経由でアクセスする場合、CA による追加の絞り込みは期待できない。**未検証**のため、CA 前提の設計をするなら別途確認が必要。

### 6.2 MCP サーバが既定で有効（見落としやすいインバウンド面）⚠️

`testpool`（`PythonLTS`、MCP を一切指定せず作成）の**実測レスポンス**:

```json
"mcpServerSettings": {
  "isMCPServerApiKeyDisabled": false,
  "isMCPServerEnabled": true,
  "mcpServerEndpoint": "https://japaneast.dynamicsessions.io/subscriptions/.../sessionPools/testpool/mcp"
}
```

**何も指定しなくても MCP サーバのエンドポイントが生え、API キー認証が無効化されていない状態**で作られる。
つまり Entra ID とは別の認証経路（API キー）が既定で開いている可能性がある。

不要なら ARM で明示的に閉じる:

```jsonc
"mcpServerSettings": {
  "isMcpServerEnabled": false          // MCP 自体が不要ならこれ
  // MCP は使うが API キー経路を閉じたい場合: "isMcpServerApiKeyDisabled": true
}
```

> **未検証**: API キーの発行方法、および API キー経路が Entra RBAC を迂回するのかは確認していない。
> レスポンスのフィールド名が `isMCPServerApiKeyDisabled`（GA `2026-01-01`）と `isMcpServerApiKeyDisabled`（preview `2026-03-02-preview`）で**大文字小文字が揺れている**ことも実測で確認済み。ARM で指定する際は api-version に合わせること。

### 6.3 Custom container プール（`azurecontainerapps.io`）— 環境レベルで制御できる

こちらは Container Apps 環境の機能がそのまま使える:

| 制御手段 | 可否 | 根拠 |
|---|---|---|
| internal VIP（VNet 統合） | ✅ | `--internal-only true` で `staticIp: 10.10.0.130` / `publicNetworkAccess: Disabled` を実測（§3.5） |
| Private Endpoint | ✅ | `groupId: managedEnvironments` で PE 作成成功（§3.5） |
| NSG | ✅ | 環境のインフラ サブネットは**自分の VNet 内**にあるため NSG を適用できる |
| 公開 DNS からの隠蔽 | ✅ | internal 環境では A レコードが公開 DNS に存在しない（`exitcode=6` を実測） |

**Private 化が要件ならこちらしか選択肢がない**のは §1 のとおりだが、**インバウンド制御の観点でも custom container が圧倒的に有利**。

---

## 7. Dynamic Session → AKS 方向の通信（AKS へのインバウンド）

### 7.0 結論 — 既定構成では発生しない

**code interpreter（`PythonLTS` 等）+ 既定設定 + Private AKS では、経路が独立に 3 重で存在しない。**

| # | 理由 | 根拠 |
|---|---|---|
| 1 | 既定が `EgressDisabled` → **セッションは一切 outbound できない** | 実測（既定値を確認）/ 公式「By default, sessions are prevented from making outbound network requests」 |
| 2 | code interpreter は **VNet に居ない**（`environmentId: null`）→ 自 VNet への経路が構造的に無い | 実測（`testpool`） |
| 3 | Private AKS に**公開エンドポイントが無い** → 仮に `EgressEnabled` にしても名前解決すら通らない | Private Cluster の定義 |

さらに**管理プレーンからのコールアウトも無い**（§7.1）。

押さえるべき発想:

> **セッションは呼び出し側のコードが命じたことしかしない。**
> LLM が生成したコードが AKS を呼ぶよう書かれない限り、そもそも何も起きない。
> そして `EgressDisabled` なら、**そう書かれていても失敗する**。

**「通常は通信が無い」は偶然ではなく、既定設計がそうなっている。**

#### 通信が発生し得る条件（すべて自分で明示的に有効化しない限り起きない）

| # | 条件 | 詳細 |
|---|---|---|
| 1 | `EgressEnabled` にする **かつ** AKS に公開面（Public API server / Public LB / Ingress）がある | → §7.3 |
| 2 | `outboundVnetSubnetId` を設定する | ⚠️ **未ドキュメント・未検証**。加えて code interpreter は環境を持たないため、そもそも効くか不明 → §7.2 |
| 3 | `managedIdentitySettings.lifecycle: Main` かつ その MI に AKS 権限がある | ⚠️ **ネットワークを完全に迂回する唯一の経路** → §7.4 |

### 7.1 管理プレーンからのコールバックは無い

リクエストの流れは **AKS → プール管理エンドポイント → セッション** の一方向で、レスポンスは同じコネクションで返る
（公式ドキュメント: 管理エンドポイント以降のパスがセッションコンテナへ転送される / [sessions-usage](https://learn.microsoft.com/en-us/azure/container-apps/sessions-usage)）。

**プールや Azure 基盤が AKS へ別途コネクションを張りに来ることはない。** よって管理プレーン起因の AKS インバウンドはゼロ。

### 7.2 セッション自身の outbound が唯一の経路

AKS に届き得るのは「サンドボックス内で動くコードが自分から外に出る」場合のみ。これは `sessionNetworkConfiguration` で決まる。

| 設定 | セッションの outbound | Private AKS への到達 | 根拠 |
|---|---|---|---|
| **`EgressDisabled`（既定）** | **一切不可** | **不可** | 実測で既定値を確認。公式: 「By default, sessions are prevented from making outbound network requests」 |
| `EgressEnabled` | インターネットへ出られる | **Private なら不可** / **Public なら到達可** | 公式: 「code running in the session can access the internet」 |
| `outboundVnetSubnetId` | 自 VNet のサブネットに注入 | **到達し得る** | ⚠️ **未検証・未ドキュメント**（下記） |

> ⚠️ **`outboundVnetSubnetId` は公式 REST 仕様に存在しない。**
> `SessionNetworkConfiguration` の定義は `status` のみ（api-version `2026-01-01` / `2025-07-01` / `2025-01-01` いずれも同じ）。
> 一方で**実 API のレスポンスには `outboundVnetSubnetId: null` が返る**ため、RP 側には実在する未公開フィールドと考えられる。
> `publicNetworkAccess`（送っても黙殺され GET に現れない＝存在しない）とは挙動が異なる点が根拠。
> **設定可能かどうか、どのプール種別で効くかは未検証。** `az containerapp sessionpool create/update` に対応する引数も存在しない（実測）。
> **本番設計の前提にしないこと。** 使う判断をするなら事前に実測が必須。

### 7.3 `EgressEnabled` にした場合の AKS 側インバウンド制御

**大前提: セッションの送信元 IP は Microsoft 管理の共有 IP であり、自分では特定も固定もできない。**
→ **送信元 IP ベースの許可リスト（NSG の source IP、AKS の authorized IP ranges）は設計として成立しない。**
ここが一番の落とし穴。「セッションからの通信だけ許可する」というルールは書けない。

| 層 | 制御 | 有効性 |
|---|---|---|
| **API Server** | **Private Cluster** | ✅ **最も確実**。API server に公開エンドポイントが無ければ、`EgressEnabled` でもセッションから到達不可 |
| **API Server** | authorized IP ranges | ❌ 送信元 IP 不定のため実質使えない。Public cluster なら「インターネット全体」を許可することになり無意味 |
| **NSG**（ノード/Pod サブネット inbound） | source = `Internet` / `AzureCloud` を Deny | ⚠️ 部分的。Public LoadBalancer / Ingress を公開しているなら、その分だけ穴が空く。`AzureCloud` は巨大なので絞り込みにならない |
| **UDR** | — | ❌ UDR は自分の egress の経路制御。外から来る通信のフィルタにはならない |
| **K8s NetworkPolicy** | Ingress ルール | ⚠️ クラスタ内の制御。外部からの通信は LoadBalancer / Ingress Controller を経て Pod に届くため、**その先の Pod 間**は絞れる。多層防御としては有効だが、入り口そのものは塞げない |
| **Ingress / LoadBalancer** | 公開 Service を作らない | ✅ そもそも公開面が無ければ到達しようがない |

### 7.4 ID 層の経路（ネットワークを完全に迂回する）⚠️ 見落としやすい

**ネットワークを塞いでも、Managed Identity 経由で AKS に到達される可能性がある。**

`managedIdentitySettings.lifecycle` を `Main` にすると、**セッション内で動く未信頼コードがプールの Managed Identity のトークンを発行できる**。
公式ドキュメントも明示的に警告している:

> If you enable access to managed identity in a session, any code or programs running in the session can create Microsoft Entra tokens for the pool's managed identity. Since sessions typically run untrusted code, use this feature with extreme caution.
> — [sessions-usage](https://learn.microsoft.com/en-us/azure/container-apps/sessions-usage)

そのトークンに AKS への権限（例: `Azure Kubernetes Service Cluster User Role`）が付いていれば、**ネットワーク制御と無関係に ARM 経由で AKS を触れる**。

| 設定 | 意味 | 実測 |
|---|---|---|
| `lifecycle: None`（既定） | セッションは identity にアクセスできない。イメージ pull 専用 | `testpool` は `managedIdentitySettings: []` = 未設定 |
| `lifecycle: Main` | **未信頼コードがトークンを発行可能。要注意** | — |

**制御: 既定の `None` のままにする。`Main` が必要な場合は、その Managed Identity に AKS 関連の権限を一切与えない。**

> **未検証（code interpreter の場合）**: 公式ドキュメントはセッション内の managed identity 利用を
> **custom container プールの文脈**でのみ説明している（「There are two ways to use managed identities with **custom container** session pools」）。
> **code interpreter（`PythonLTS`）で `lifecycle: Main` が実際に使えるかは確認していない。**
> ただし `az containerapp sessionpool create` には `--mi-system-assigned` / `--mi-user-assigned` が
> **プール種別に関わらず存在する**（実測）ため、可能性は排除できない。
> code interpreter でこの経路を塞いだつもりになる前に、実測で確認すること。

### 7.5 まとめ — 推奨する既定

```
[最強かつ既定] sessionNetworkConfiguration.status = EgressDisabled
               → セッションは一切 outbound できない。AKS インバウンドは原理的に発生しない。
               → NSG も NetworkPolicy も「念のため」の多層防御であって、主防御ではない。

[EgressEnabled が必要な場合]
  1. AKS を Private Cluster にする              ← 主防御
  2. 公開 Service / Ingress を作らない            ← 主防御
  3. NetworkPolicy で Pod 間を絞る                ← 多層防御
  4. authorized IP ranges は当てにしない          ← 送信元 IP 不定のため

[ID 層・ネットワークとは独立]
  5. managedIdentitySettings.lifecycle = None を維持（既定）
  6. Main が必要なら、その MI に AKS 権限を与えない
```

**要点: 「セッション → AKS」を防ぐ最も確実な手段は NW 制御ではなく、`EgressDisabled` を維持することと AKS を Private Cluster にすること。**
送信元 IP が特定できない以上、IP ベースのフィルタに頼る設計は成立しない。

---

## 8. AKS 側の設定要点

1. **Workload Identity** を有効化し、ServiceAccount にフェデレーション資格情報を紐付け
2. その Managed Identity に **`Azure ContainerApps Session Executor`** をプールスコープで付与
3. アプリ側は audience **`https://dynamicsessions.io`** でトークン取得

```python
from azure.identity import DefaultAzureCredential
cred = DefaultAzureCredential()
token = cred.get_token("https://dynamicsessions.io/.default").token
```

---

## 9. 参考 URL

### Container Apps Dynamic Sessions
- [Dynamic sessions in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/sessions) — プール種別の比較、対応リージョン（Japan East 含む）
- [Use session pools](https://learn.microsoft.com/en-us/azure/container-apps/session-pool) — 管理エンドポイント形式、`--network-status`、エンドポイントパス一覧
- [Use dynamic sessions](https://learn.microsoft.com/en-us/azure/container-apps/sessions-usage) — 認証・認可、`aud=https://dynamicsessions.io`、RBAC 付与コマンド、Network access
- [Serverless Code Interpreter Sessions](https://learn.microsoft.com/en-us/azure/container-apps/sessions-code-interpreter) — code interpreter の REST API、audience 明記
- [Custom container sessions](https://learn.microsoft.com/en-us/azure/container-apps/sessions-custom-container) — custom container プール
- [SessionPools REST API (Create or Update)](https://learn.microsoft.com/en-us/rest/api/resource-manager/containerapps/container-apps-session-pools/create-or-update) — ARM スキーマ

### ネットワーク / Private Link
- [Use a private endpoint with an Azure Container Apps environment](https://learn.microsoft.com/en-us/azure/container-apps/how-to-use-private-endpoint) — 環境への PE（workload profiles 環境のみ対応）
- [Networking in an Azure Container Apps Environment](https://learn.microsoft.com/en-us/azure/container-apps/networking) — internal / external VIP
- [Integrate a virtual network with an Azure Container Apps environment](https://learn.microsoft.com/en-us/azure/container-apps/vnet-custom) — VNet 統合、subnet delegation
- [Configure Private Endpoints and DNS for VNets in ACA](https://learn.microsoft.com/en-us/azure/container-apps/private-endpoints-with-dns)
- [Private Endpoint overview](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview) — PE 対応リソース一覧（※表より §3.1 の API 実測が確実）
- [Private Endpoint DNS zone values](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns) — privatelink ゾーン名一覧
- [Service tags overview](https://learn.microsoft.com/en-us/azure/virtual-network/service-tags-overview) — `ContainerAppsManagement` の定義

### AKS / Firewall
- [Control egress traffic for AKS cluster nodes](https://learn.microsoft.com/en-us/azure/aks/outbound-rules-control-egress) — AKS 必須エグレス（`login.microsoftonline.com` 含む）
- [Use Azure Firewall to secure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/use-azure-firewall)
- [Azure Firewall FQDN tags](https://learn.microsoft.com/en-us/azure/firewall/fqdn-tags) — Dynamic Sessions 用の FQDN タグは存在しない
- [Use Microsoft Entra Workload ID with AKS](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Create a private Azure Kubernetes Service cluster](https://learn.microsoft.com/en-us/azure/aks/private-clusters) — §7.3 の主防御
- [Secure access to the API server using authorized IP address ranges](https://learn.microsoft.com/en-us/azure/aks/api-server-authorized-ip-ranges) — §7.3 で「使えない」と判断した機能
- [Secure traffic between pods using network policies in AKS](https://learn.microsoft.com/en-us/azure/aks/use-network-policies)
- [Use a network security group in Azure Kubernetes Service](https://learn.microsoft.com/en-us/azure/aks/concepts-security#azure-network-security-groups)

---

## 10. 検証で作成し削除済みのリソース

| RG | 内容 | 状態 |
|---|---|---|
| `rg-dynsess-test` | code interpreter プール `testpool`, `vnet-test` | 削除済み |
| `rg-dynsess-priv` | internal 環境 `env-priv`, custom container プール `pool-custom`, PE `pe-env`, `vnet-ca` | 削除済み |
