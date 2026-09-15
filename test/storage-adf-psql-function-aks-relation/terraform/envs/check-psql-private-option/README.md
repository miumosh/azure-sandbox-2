# check-psql-private-option

PostgreSQL Flexible Server を **VNet 統合（委任サブネット）** で構成したとき、
ADF の Managed VNet から接続するための PostgreSQL の
**Managed Private Endpoint（`azapi_resource` 利用）** が問題なく構成でき、
**ADF から実際にアクセスできるか** を確認するためだけの最小構成 env です。

本番 `modules/` には依存しない自己完結構成です。

## 構成するもの

| リソース | 役割 |
| --- | --- |
| Resource Group | 検証一式の入れ物 |
| VNet `10.50.0.0/16` + `snet-psql-delegated` `10.50.1.0/24` | `Microsoft.DBforPostgreSQL/flexibleServers` へ delegation した委任サブネット |
| Private DNS Zone `ci00chk.private.postgres.database.azure.com` + VNet リンク | VNet 統合モードの Flexible Server が要求する専用ゾーン |
| PostgreSQL Flexible Server | `delegated_subnet_id` + `private_dns_zone_id` で **VNet 統合**（public 無効） |
| Data Factory | `managed_virtual_network_enabled = true` / public 無効 |
| ManagedVnetIR | Managed VNet で動く Azure IR（`default` managed VNet を具現化） |
| **ADF Managed Private Endpoint**（`azapi_resource`） | **検証の核心**。`groupId = postgresqlServer` で PostgreSQL を指す |
| PostgreSQL Linked Service（`azapi_resource`） | ADF Studio の「テスト接続」で到達可否を見るための Basic 認証 LS |

## 使い方

```bash
cd terraform/envs/check-psql-private-option
cp terraform.tfvars.sample terraform.tfvars   # 値を埋める
terraform init
terraform apply
```

> **注意:** `enable_adf_mpe = true`（既定）の apply は **MPE 作成段階で意図的に失敗します**
> （それ自体が検証結果。後述「確定した検証結果」参照）。`timeouts { create = "10m" }` で
> 約10分でタイムアウト失敗します。
>
> - VNet 統合 PostgreSQL + ManagedVNet ADF の **土台だけ** を正常に立てたい場合は
>   `enable_adf_mpe = false` で apply してください。

## 確認手順

1. **MPE の状態**

   ```bash
   az datafactory managed-private-endpoint show \
     --factory-name $(terraform output -raw data_factory_name) \
     --resource-group $(terraform output -raw resource_group_name) \
     --managed-virtual-network-name default \
     --name mpe-psql
   ```

   `terraform output adf_managed_private_endpoint_state` でも provisioningState /
   connectionState を確認できます。

2. **PostgreSQL 側の Private Endpoint 接続要求**（Pending なら承認）

   ```bash
   az network private-endpoint-connection list \
     --id $(terraform output -raw psql_server_id)
   # Pending があれば:
   az network private-endpoint-connection approve --id <connection-id> --description "approved for check"
   ```

3. **ADF からの到達確認**

   ADF Studio → Manage → Linked services → `ls_psql_check` → **Test connection**
   （`ManagedVnetIR` 経由）を実行し、成功するかを確認します。

## 確定した検証結果（実機で確認済み・重要）

**結論: 成立しない。** VNet 統合（委任サブネット）で構成した Flexible Server は
**Private Endpoint 機能を非対応**であり、ADF の Managed VNet から MPE で繋ぐ構成は作れない。
Flexible Server では **「VNet 統合」と「Private Endpoint」は排他**。

実機 apply で観測した事実:

1. ADF MPE `mpe-psql` は `provisioningState: Provisioning` のまま終端状態に到達せず、
   apply が長時間ハングする（azapi が create タイムアウトまでポーリングし続けるため）。
   → 本 env では `timeouts { create = "10m" }` で約10分後に明示的に失敗させる。

2. PostgreSQL 側に private link リソースを問い合わせると、明確に非対応エラーが返る:

   ```bash
   az network private-link-resource list --id $(terraform output -raw psql_server_id)
   # ERROR: PrivateEndpointFeatureNotSupportedOnServer:
   #   The given server ... does not support private endpoint feature.
   #   Please create a new server that is private endpoint capable.
   #   https://aka.ms/pgflex-pepreview
   ```

3. サーバのネットワーク設定は VNet 統合モードそのもの（`privateEndpointConnections`
   プロパティ自体が存在しない）:

   ```bash
   az resource show --ids $(terraform output -raw psql_server_id) \
     --api-version 2023-06-01-preview --query "properties.network"
   # => delegatedSubnetResourceId が設定され, publicNetworkAccess: "Disabled"
   ```

### 繋ぐ必要がある場合の代替案（参考）

- PostgreSQL を **VNet 統合ではなく Private Endpoint モード**（public access +
  Private Endpoint、Flexible Server の PE 機能）で構成し、ADF Managed VNet から
  MPE を張る。本リポジトリの `modules/postgresql` + `modules/private_endpoint` /
  ADF 側 MPE がこの方式に相当。
- ADF の Managed VNet はピアリング不可のため、**MPE 以外で Managed VNet から
  VNet 統合サーバへ直接到達する経路は無い**点に注意。

## 後片付け

```bash
terraform destroy
```
