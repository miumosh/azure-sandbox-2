# ============================================================================
# 検証対象: Defender for Azure Cosmos DB
#
# azurerm_advanced_threat_protection でアカウント単位に有効化する
# (Microsoft.Security/advancedThreatProtectionSettings/current 拡張リソース)。
#
# キー認証 (local auth) を無効化し、データ操作は Entra ID + Cosmos DB データプレーン RBAC に限定する。
# ※ azurerm は local auth 無効でも primary_key 等を state に保存する。state は絶対にコミットしない。
# ============================================================================
resource "azurerm_cosmosdb_account" "this" {
  count = var.targets.cosmosdb ? 1 : 0

  name                = local.cosmosdb.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  local_authentication_enabled = false

  # 接続元を allowed_client_ips に限定する (空なら外部からデータプレーンに到達不可)
  public_network_access_enabled = true
  ip_range_filter               = var.allowed_client_ips

  capabilities {
    name = "EnableServerless"
  }

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.this.location
    failover_priority = 0
  }

  tags = local.tags
}

resource "azurerm_cosmosdb_sql_database" "this" {
  count = var.targets.cosmosdb ? 1 : 0

  name                = local.cosmosdb.database_name
  resource_group_name = azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this[0].name
}

resource "azurerm_cosmosdb_sql_container" "this" {
  count = var.targets.cosmosdb ? 1 : 0

  name                = local.cosmosdb.container_name
  resource_group_name = azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this[0].name
  database_name       = azurerm_cosmosdb_sql_database.this[0].name
  partition_key_paths = ["/id"]
}

# 実行ユーザーにデータプレーンの読み書き権限を付与する (キーを使わずにアクセスするため)
resource "azurerm_cosmosdb_sql_role_assignment" "current_user" {
  count = var.targets.cosmosdb ? 1 : 0

  resource_group_name = azurerm_resource_group.this.name
  account_name        = azurerm_cosmosdb_account.this[0].name
  role_definition_id  = "${azurerm_cosmosdb_account.this[0].id}/sqlRoleDefinitions/${local.cosmosdb.data_contributor_role_id}"
  principal_id        = data.azurerm_client_config.current.object_id
  scope               = azurerm_cosmosdb_account.this[0].id
}

resource "azurerm_advanced_threat_protection" "cosmosdb" {
  count = var.targets.cosmosdb ? 1 : 0

  target_resource_id = azurerm_cosmosdb_account.this[0].id
  enabled            = true

  depends_on = [azurerm_security_center_subscription_pricing.this]
}
