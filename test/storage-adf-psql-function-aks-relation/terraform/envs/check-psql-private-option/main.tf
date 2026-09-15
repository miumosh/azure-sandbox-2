# ============================================================================
# check-psql-private-option env ルート
#
# 検証目的:
#   PostgreSQL Flexible Server を「VNet 統合 (委任サブネット)」で構成したとき、
#   ADF の Managed VNet から接続するための PostgreSQL の
#   Managed Private Endpoint (azapi_resource) が構成でき、ADF から実際に
#   アクセスできるかを確認する。
#
# 構成:
#   RG
#   └ VNet (10.50.0.0/16)
#       └ snet-psql-delegated (10.50.1.0/24, flexibleServers へ delegation)
#   Private DNS Zone (*.private.postgres.database.azure.com) + VNet リンク
#   PostgreSQL Flexible Server (delegated_subnet_id + private_dns_zone_id = VNet 統合)
#   Data Factory (Managed VNet 有効 / public 無効)
#   └ ManagedVnetIR (virtual_network_enabled)
#   └ Managed Private Endpoint  ... azapi_resource (groupId=postgresqlServer)
#   └ PostgreSQL Linked Service ... azapi_resource (Basic 認証 / Test connection 用)
#
# ※ 期待結果・確認手順・既知の論点は README.md を参照。
# ============================================================================

# ADF / PostgreSQL 名はグローバル一意のため乱数サフィックスを付与する
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}

# ---- ネットワーク (VNet + 委任サブネット + Private DNS Zone) ------------------
resource "azurerm_virtual_network" "main" {
  name                = local.vnet.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = local.vnet.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "psql" {
  name                 = local.psql_subnet.name
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = local.psql_subnet.address_prefixes

  # Flexible Server を VNet 注入するための delegation
  delegation {
    name = "flexibleServers-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "psql" {
  name                = local.private_dns_zone_name
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "psql" {
  name                  = "psql-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.psql.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
}

# ---- PostgreSQL Flexible Server (VNet 統合 / 委任サブネット) ------------------
resource "azurerm_postgresql_flexible_server" "main" {
  name                = "${local.prefix}-psql-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  version    = "16"
  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768

  administrator_login    = local.psql_admin_login
  administrator_password = var.psql_admin_password

  # VNet 統合: 委任サブネットに注入し、専用 Private DNS Zone を割り当てる。
  # VNet 統合時は public access と排他のため明示的に無効化する
  # (未指定だと provider が true を送り ConflictingPublicNetworkAccess... で 400)。
  public_network_access_enabled = false
  delegated_subnet_id           = azurerm_subnet.psql.id
  private_dns_zone_id           = azurerm_private_dns_zone.psql.id

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  authentication {
    password_auth_enabled = true
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }

  # 委任サブネットへの注入は Private DNS リンク確立後に行う
  depends_on = [azurerm_private_dns_zone_virtual_network_link.psql]
}

resource "azurerm_postgresql_flexible_server_database" "check" {
  name      = local.psql_database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# ---- Data Factory (Managed VNet) --------------------------------------------
resource "azurerm_data_factory" "main" {
  name                = "${local.prefix}-adf-${random_string.suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  managed_virtual_network_enabled = true
  public_network_enabled          = false

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# AutoResolveIntegrationRuntime を Managed VNet で動作させる。
# これにより factories/.../managedVirtualNetworks/default が確実に具現化される。
resource "azurerm_data_factory_integration_runtime_azure" "managed" {
  name                    = "ManagedVnetIR"
  data_factory_id         = azurerm_data_factory.main.id
  location                = "AutoResolve"
  virtual_network_enabled = true
  compute_type            = "General"
  core_count              = 8
  time_to_live_min        = 0
}

# ---- ADF Managed Private Endpoint (azapi) -----------------------------------
# 本検証の核心。VNet 統合 (委任サブネット) で構成した PostgreSQL に対して、
# ADF の Managed VNet から Managed Private Endpoint を張れるかを確認する。
#
# 【確定した検証結果】成立しない。
#   VNet 統合 (委任サブネット) の Flexible Server は Private Endpoint 機能を非対応で、
#   PostgreSQL 側に private link リソース (postgresqlServer) が公開されない:
#     PrivateEndpointFeatureNotSupportedOnServer:
#       "The given server ... does not support private endpoint feature."
#   そのため MPE は provisioningState=Provisioning のまま終端状態に到達せず、
#   azapi が create タイムアウトまでポーリングし続ける (= apply がハングし最終的に失敗)。
#   下の timeouts で ~10分で fail-fast させる (既定 30分のハングを回避)。詳細は README。
resource "azapi_resource" "psql_mpe" {
  count = var.enable_adf_mpe ? 1 : 0

  type      = "Microsoft.DataFactory/factories/managedVirtualNetworks/managedPrivateEndpoints@2018-06-01"
  name      = "mpe-psql"
  parent_id = "${azurerm_data_factory.main.id}/managedVirtualNetworks/default"

  body = {
    properties = {
      privateLinkResourceId = azurerm_postgresql_flexible_server.main.id
      groupId               = "postgresqlServer"
      fqdns                 = [azurerm_postgresql_flexible_server.main.fqdn]
    }
  }

  schema_validation_enabled = false

  # MPE 作成完了 (provisioningState=Succeeded) まで待つ。
  response_export_values = ["properties.provisioningState", "properties.connectionState"]

  # VNet 統合 PSQL では終端に到達しないため、既定 30分ではなく ~10分で失敗させる。
  timeouts {
    create = "10m"
  }

  depends_on = [azurerm_data_factory_integration_runtime_azure.managed]
}

# ---- PostgreSQL Linked Service (azapi / Basic 認証) --------------------------
# ADF Studio の「テスト接続」で実際に到達できるかを確認するための Linked Service。
# 検証なので MI ロール作成不要の Basic (管理者ログイン) 認証を使う。
resource "azapi_resource" "psql_linked_service" {
  count = var.enable_adf_mpe ? 1 : 0

  type                      = "Microsoft.DataFactory/factories/linkedservices@2018-06-01"
  name                      = "ls_psql_check"
  parent_id                 = azurerm_data_factory.main.id
  schema_validation_enabled = false

  body = {
    properties = {
      type        = "AzurePostgreSql"
      version     = "2.0"
      annotations = []
      typeProperties = {
        server             = azurerm_postgresql_flexible_server.main.fqdn
        port               = 5432
        database           = local.psql_database_name
        sslMode            = 2 # 2=Prefer (Flexible Server は SSL 必須のため実際は SSL になる)
        authenticationType = "Basic"
        username           = local.psql_admin_login
        password = {
          type  = "SecureString"
          value = var.psql_admin_password
        }
      }
      connectVia = {
        referenceName = azurerm_data_factory_integration_runtime_azure.managed.name
        type          = "IntegrationRuntimeReference"
      }
    }
  }

  depends_on = [azapi_resource.psql_mpe]
}
