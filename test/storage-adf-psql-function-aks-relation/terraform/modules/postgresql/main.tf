# ============================================================================
# postgresql モジュール (Azure Database for PostgreSQL Flexible Server)
# - ネットワークは Private Endpoint 方式 (public 無効・VNet 注入は不使用)。
#   PE / Private DNS Zone は呼び出し側 (env / network) が持つ。
# - Entra ID 認証を有効化 (ADF / Function は MI で接続)。password 認証も bootstrap 用に併存。
# ============================================================================
resource "azurerm_postgresql_flexible_server" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name

  version    = var.postgresql_version
  sku_name   = var.sku_name
  storage_mb = var.storage_mb

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  # Private Endpoint 方式 (VNet 注入は使わない)
  public_network_access_enabled = false

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = true
    tenant_id                     = var.entra_admin_tenant_id
  }

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = false

  tags = var.tags

  lifecycle {
    ignore_changes = [zone, high_availability[0].standby_availability_zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = var.charset
  collation = var.collation
}

# Entra ID 管理者 (この管理者で psql に AAD 接続し MI ロールを作成する)
resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  server_name         = azurerm_postgresql_flexible_server.this.name
  resource_group_name = var.resource_group_name
  tenant_id           = var.entra_admin_tenant_id
  object_id           = var.entra_admin_object_id
  principal_name      = var.entra_admin_principal_name
  principal_type      = var.entra_admin_principal_type
}
