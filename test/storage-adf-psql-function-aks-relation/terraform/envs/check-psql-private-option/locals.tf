# ============================================================================
# check-psql-private-option env 設定値
# ============================================================================
locals {
  location = "japaneast"
  prefix   = "ci00chk"

  tags = {
    project = "storage-adf-psql-function-aks-relation"
    env     = "test"
    purpose = "check-psql-vnet-integration-adf-mpe"
  }

  resource_group_name = "${local.prefix}-rg"

  # ---- ネットワーク -------------------------------------------------------
  vnet = {
    name          = "${local.prefix}-vnet"
    address_space = ["10.50.0.0/16"]
  }

  # PostgreSQL Flexible Server を注入する委任サブネット。
  # Microsoft.DBforPostgreSQL/flexibleServers への delegation が必須。
  psql_subnet = {
    name             = "snet-psql-delegated"
    address_prefixes = ["10.50.1.0/24"]
  }

  # VNet 統合モードの Flexible Server が要求する Private DNS Zone。
  # Private Endpoint モードの "privatelink.postgres..." とは別物で、
  # "*.private.postgres.database.azure.com" 形式の専用ゾーンを使う。
  private_dns_zone_name = "${local.prefix}.private.postgres.database.azure.com"

  psql_database_name = "checkdb"
  psql_admin_login   = "psqladmin"
}
