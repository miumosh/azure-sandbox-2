# ネットワーク制御（閉域化）整理

VNet / サブネット / Private Endpoint / Private DNS / NSG / ピアリングの構成と、
「どの閉域化パターンを、どの通信に、なぜ選んだか」を整理する。

---

## 1. VNet とサブネット一覧

Hub と Spoke は別サブスクリプションのため 1 つの VNet を共有できない。
→ **2 つの VNet を VNet ピアリングで接続**して閉域通信を実現する。

### Hub VNet — `10.39.0.0/16`（`modules/network`）

| サブネット | CIDR | 配置されるもの | 備考 |
| --- | --- | --- | --- |
| `AzureBastionSubnet` | 10.39.1.0/24 | Azure Bastion | 名前固定 |
| `snet-jumpbox` | 10.39.2.0/24 | 踏み台 VM（psql 実行元） | |
| `snet-pe-storage` | 10.39.10.0/24 | **Storage blob PE** | `private_endpoint_network_policies = Disabled` |

### Spoke VNet — `10.40.0.0/16`（`modules/network`）

| サブネット | CIDR | 配置されるもの | 備考 |
| --- | --- | --- | --- |
| `snet-aks` | 10.40.1.0/24 | AKS ノード/Pod（Azure CNI） | NSG `snet-aks-nsg` |
| `snet-pe-psql` | 10.40.10.0/24 | **PostgreSQL PE** | PE policies = Disabled |
| `snet-pe-func` | 10.40.11.0/24 | **Functions inbound PE** | PE policies = **Enabled**（NSG を効かせるため）、NSG `snet-pe-func-nsg` |
| `snet-func-int` | 10.40.20.0/24 | **Functions VNet 統合（outbound）** | `Microsoft.Web/serverFarms` にデリゲート |

> ADF は **Managed VNet**（Microsoft 管理）を使うため、自前の VNet 内に専用サブネットを持たない。

---

## 2. Private Endpoint がどのネットワークに置かれるか

| 接続対象 | PE 種別 | 配置先ネットワーク | 定義場所 |
| --- | --- | --- | --- |
| Storage（blob, 自前 inbound PE） | 自前作成 PE | **Hub VNet / `snet-pe-storage`** | `modules/storage` |
| PostgreSQL Flexible Server（自前 inbound PE） | 自前作成 PE | **Spoke VNet / `snet-pe-psql`** | `modules/postgresql` |
| Functions（自前 inbound PE） | 自前作成 PE | **Spoke VNet / `snet-pe-func`** | `modules/function_app` |
| ACR（Premium, 自前 inbound PE） | 自前作成 PE | **Hub VNet / `snet-pe-acr`** | `modules/container_registry` |
| ADF → Storage(blob) | **ADF Managed PE** | **ADF Managed VNet（Microsoft 管理）** | `modules/data_factory` (`mpe-storage-blob`) |
| ADF → PostgreSQL | **ADF Managed PE**（cross-sub） | **ADF Managed VNet（Microsoft 管理）** | `modules/data_factory` (`mpe-psql`) |
| Functions → PostgreSQL | VNet 統合（PE ではない） | **Spoke VNet / `snet-func-int`**（出口） | `modules/function_app` |

ポイント:
- **自前 PE** は自分のサブネットに NIC が立ち、`private_endpoint_network_policies` と NSG の対象にできる。
- **ADF Managed PE** は Microsoft 管理 VNet 側に立つため、自前サブネット/NSG の対象外。
  代わりに「対象リソース側で接続を承認」する運用が必要（README 手順 3-b）。
- **PostgreSQL は Private Endpoint 方式**（VNet 統合＝委任サブネット注入は不使用）。詳細は下記「PostgreSQL の閉域方式」。

### PostgreSQL の閉域方式 — VNet 統合（委任サブネット）ではなく Private Endpoint

PostgreSQL Flexible Server の閉域化には 2 方式があり、**本構成は Private Endpoint 方式**を採用している。

| 方式 | 概要 | 本構成 |
| --- | --- | --- |
| VNet 統合（委任サブネット注入） | サーバ自体を委任サブネット（`Microsoft.DBforPostgreSQL/flexibleServers`）へ注入し、サーバ NIC をそのサブネットに入れる | ❌ 不採用 |
| **Private Endpoint** | サーバは `public_network_access_enabled = false` で非公開にし、別途 PE をサブネットに立てて接続する | ✅ 採用 |

実装（`modules/postgresql`）:

- `azurerm_postgresql_flexible_server.main` … `public_network_access_enabled = false`。
  `delegated_subnet_id` / `private_dns_zone_id` は**指定しない**（＝委任サブネット注入は不使用）。
- `azurerm_private_endpoint.psql` … `snet-pe-psql` に PE を作成
  （`subresource_names = ["postgresqlServer"]`、`is_manual_connection = false` で自動承認）。
  `private_dns_zone_group` で `privatelink.postgres.database.azure.com` を紐付けて名前解決する。

**なぜ Private Endpoint 方式か**:

- **ADF の Managed Private Endpoint（cross-subscription）から到達させるため**。VNet 統合（委任サブネット）
  方式だと ADF の Managed VNet から PostgreSQL へ届かない。PE 方式なら ADF Managed PE（`postgresqlServer`）からも、
  Functions の VNet 統合（outbound）からも到達できる。
- 到達経路:
  - **Functions → PostgreSQL**: VNet 統合（`snet-func-int`）→ PSQL PE（`snet-pe-psql`）/ psql ゾーン
  - **ADF → PostgreSQL**: ADF Managed PE（`mpe-psql`、手動承認）→ PSQL PE
  - **踏み台 VM → PostgreSQL**: Hub VNet → ピアリング + psql ゾーン Hub リンク → PSQL PE

---

## 3. Private DNS Zone とリンク

PE の FQDN を私設 IP に解決するためのゾーンとリンク先 VNet。

| ゾーン | 定義場所 | リンク先 VNet |
| --- | --- | --- |
| `privatelink.blob.core.windows.net` | `modules/network` | Hub VNet |
| `privatelink.postgres.database.azure.com` | `modules/network` | Spoke VNet ＋（Hub apply 後）Hub VNet |
| `privatelink.azurewebsites.net` | `modules/network` | Spoke VNet |
| `privatelink.azurecr.io` | `modules/container_registry` | Hub VNet ＋（spoke_vnet_id 設定時）Spoke VNet |

- PostgreSQL ゾーンを **Hub VNet にもリンク**するのは、踏み台 VM から PSQL を名前解決するため
  （`psql_hub` リンク、`hub_vnet_id` 設定時のみ）。
- ACR ゾーンを **Spoke VNet にもリンク**するのは、AKS が Hub の ACR PE を名前解決して pull するため
  （`acr_spoke` リンク）。registry / data エンドポイントの A レコードは PE が自動作成する。
- ADF Managed VNet は**自前で DNS 解決**するため、ADF 用に自前ゾーンは不要。

---

## 4. NSG（L4 制御）

| NSG | 関連サブネット | ルール（要旨） | 定義場所 |
| --- | --- | --- | --- |
| `snet-pe-func-nsg` | `snet-pe-func` | inbound: `snet-aks`→443 許可 / AzureLoadBalancer 許可 / その他 VNet は deny | `modules/network` |
| `snet-aks-nsg` | `snet-aks` | inbound: `Internet`→**port 80**(`*`) 許可（公開 LB の Web UI） / outbound: `snet-pe-func`:443 を明示許可 | `modules/network` |

- func PE への到達を「AKS サブネットのみ」に制限する**決定的な制御点**は `snet-pe-func-nsg`。
- NSG を PE に効かせるため `snet-pe-func` は `private_endpoint_network_policies = "Enabled"`。
- AKS はイメージ取得や Azure API へ広範な egress が必要なため、AKS 側 egress は全 deny にしない。

### ⚠️ カスタム subnet NSG と 公開 LoadBalancer Service（ハマりどころ）

AKS の node subnet に**カスタム NSG を付けると、公開 LoadBalancer Service（Web UI）への
クライアント通信を自分で許可しないと届かない**。実機で詰まった点:

- **AKS は LB 用 inbound 許可を「AKS 管理 NSG（NIC 側 `aks-agentpool-*-nsg`、MC_ RG）」にだけ
  自動追加**し、ユーザー作成の subnet NSG には追加しない。両方が許可しないと通らないため、
  subnet NSG の既定 `DenyAllInBound` で SYN が落ち、`curl` がハングする（READY な Pod でも繋がらない）。
- **Azure LB は floating IP / DSR で動く**ため、ノードに届くパケットは
  **宛先ポート = サービスポート（80）／宛先 IP = LB 公開 IP**（nodePort 31454 や subnet 宛**ではない**）。
  → NSG ルールは `Internet → port 80 → dst "*"` で許可する（`nodePort` レンジや `subnet` 宛では一致しない）。
- アクセス元を絞るなら `source_address_prefix` を `Internet` から自分のグローバル IP へ変更する。
- 切り分け: `kubectl get pod`(Running 1/1) + `kubectl get endpoints`(あり) なのに LB 無応答 →
  `az network nsg rule list`（subnet NSG）と `az network lb rule list`（`frontendPort`/`backendPort`/probe）を確認。
  AKS 管理側ルールは `az network nsg rule show ... -n k8s-azure-lb_allow_* --query dsts/dports` で正解値が分かる。

---

## 5. VNet ピアリング

| ピアリング | 定義場所 | 作成条件 |
| --- | --- | --- |
| Hub → Spoke | `modules/network` (`hub_to_spoke`) | `spoke_vnet_id` 設定時 |
| Spoke → Hub | `modules/network` (`spoke_to_hub`) | `hub_vnet_id` 設定時 |

相互参照のため apply は **Spoke → Hub → Spoke 再apply** の順（README デプロイ手順参照）。

---

## 6. 閉域化パターンと今回の選定

PaaS へ閉域接続する代表パターンと、本構成での採否・理由。

| パターン | 概要 | 本構成での採用 |
| --- | --- | --- |
| **自前 Private Endpoint** | 自分のサブネットに PE NIC ＋ Private DNS。NSG/ポリシー対象にできる | ✅ Storage / PostgreSQL / Functions(inbound) |
| **Managed VNet + Managed PE（ADF 専用）** | ADF 専用の Microsoft 管理 VNet から Managed PE。自前サブネット不要・DNS 内部解決 | ✅ ADF → Storage / PostgreSQL |
| **VNet 統合（App Service/Functions の outbound）** | 委任サブネットから VNet へ出ていく。受信ではなく送信側 | ✅ Functions → PostgreSQL |
| **VNet ピアリング** | 別 VNet（別サブスク）同士を接続 | ✅ Hub ⇔ Spoke |
| **Service Endpoint** | サブネット単位でサービスを許可（PE より分離が弱い） | ❌ PE を優先するため不採用 |
| **Private Cluster（AKS）** | API サーバを私設化 | ❌ 検証簡略化のため不採用（kubeconfig をパブリック API で取得） |

### 選定理由

- **2 サブスクリプション構成**：単一 VNet を跨げないため Hub-Spoke + ピアリングを採用。
  architecture.md の「同一 VNet」要件は、ピアリングによる等価な閉域通信で満たす。
- **ADF だけ Managed VNet**：ADF は自前サブネットに注入できない。Managed VNet + Managed PE が
  Microsoft 推奨の閉域パターンのため採用（cross-subscription の PostgreSQL もリソース ID 指定で到達可）。
- **Functions の inbound/outbound 分離**：受信は PE（`snet-pe-func`）、PostgreSQL への送信は
  VNet 統合（`snet-func-int`）。`vnet_route_all_enabled = true` で全 outbound を VNet 経由にする。
- **AKS→Functions は 2 層**：網（同一 VNet + PE + NSG）＋ 認証（Function キー / `x-functions-key`）。
  詳細は [auth.md](./auth.md)。

---

## 7. 通信フロー（閉域 / 非閉域の別）

| 経路 | 閉域? | 経由 |
| --- | --- | --- |
| Storage Explorer → Storage | ❌ 非閉域（設計上） | インターネット + SAS + IP allowlist（architecture 要件） |
| ADF → Storage(blob) | ✅ 閉域 | ADF Managed VNet → Managed PE |
| ADF → PostgreSQL | ✅ 閉域（cross-sub） | ADF Managed VNet → Managed PE |
| Functions → PostgreSQL | ✅ 閉域 | `snet-func-int`（VNet 統合）→ PSQL PE（`snet-pe-psql`）/ private DNS |
| AKS → Functions | ✅ 閉域 | `snet-aks` → Functions PE（`snet-pe-func`）/ private DNS / NSG |
| 踏み台 VM → PostgreSQL | ✅ 閉域 | `snet-jumpbox` → ピアリング → PSQL PE（`snet-pe-psql`）/ psql ゾーン Hub リンク |
| 踏み台 VM → Storage | ✅ 閉域 | `snet-jumpbox` → Storage blob PE（`snet-pe-storage`）/ blob ゾーン Hub リンク |
| AKS → ACR（イメージ pull） | ✅ 閉域 | `snet-aks` → ピアリング → ACR PE（Hub `snet-pe-acr`）/ acr ゾーン Spoke リンク / AcrPull |
| 開発者 → ACR（push） | ⚠️ デプロイ時のみ public | `az acr build`。push の間だけ `acr_public_network_access_enabled=true`、完了後 false |
| ブラウザ → AKS Web UI | ❌ 非公開でない（公開 LB） | 公開 LoadBalancer（Web UI を人間が閲覧）。`snet-aks-nsg` で `Internet→80` 許可 |

> Storage の public は「IP allowlist + SAS」のみ開放（`network_rules` 既定 Deny）。
> PE トラフィックは network ACL をバイパスするため、ADF/踏み台からの私設接続は許可 IP に依存しない。
> ACR は pull が常時閉域（PE）、push のみ一時 public。AKS の Web UI は公開 LB（認証なし）で人間がアクセスする。

## 関連

- ID・権限・認証方式は [auth.md](./auth.md) を参照。
- ADF 取り込みパイプラインの構成・落とし穴は [pipeline.md](./pipeline.md) を参照。
