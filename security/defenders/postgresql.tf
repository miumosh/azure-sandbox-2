# ============================================================================
# 検証対象: Defender for open-source relational databases (PostgreSQL フレキシブルサーバー)
#
# azurerm にリソース単位の有効化リソースが無いため、サーバーの子リソース
#   Microsoft.DBforPostgreSQL/flexibleServers/advancedThreatProtectionSettings/Default
# を azapi で作る。
#
# パスワード認証を無効化し Entra 認証のみにする。管理者パスワードを変数 / state に
# 持たないので、シークレットの流出経路そのものを無くせる。
# ============================================================================
resource "azurerm_postgresql_flexible_server" "this" {
  count = var.targets.postgresql ? 1 : 0

  name                = local.postgresql.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku_name            = local.postgresql.sku_name
  version             = local.postgresql.version
  storage_mb          = local.postgresql.storage_mb

  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true # 接続元は firewall rule で allowed_client_ips に限定する

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = data.azurerm_client_config.current.tenant_id
  }

  tags = local.tags

  lifecycle {
    # 可用性ゾーンは Azure 側が自動で割り当てるため差分にしない
    ignore_changes = [zone]

    precondition {
      condition     = var.postgresql_entra_admin_upn != null
      error_message = "targets.postgresql = true の場合は postgresql_entra_admin_upn を指定してください。"
    }
  }
}

resource "azurerm_postgresql_flexible_server_active_directory_administrator" "this" {
  count = var.targets.postgresql ? 1 : 0

  server_name         = azurerm_postgresql_flexible_server.this[0].name
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  object_id           = data.azurerm_client_config.current.object_id
  principal_name      = var.postgresql_entra_admin_upn
  principal_type      = "User"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "client" {
  for_each = var.targets.postgresql ? toset(var.allowed_client_ips) : toset([])

  name             = "client-${replace(each.value, ".", "-")}"
  server_id        = azurerm_postgresql_flexible_server.this[0].id
  start_ip_address = each.value
  end_ip_address   = each.value
}

# advancedThreatProtectionSettings/Default はサーバー作成時から存在する固定名の子リソースで、
# API に DELETE が無い (CreateOrUpdate / Get / List のみ)。そのため azapi_resource ではなく
# azapi_update_resource で state だけ上書きする。destroy 時は何もしない (サーバーごと消える)。
resource "azapi_update_resource" "postgresql_defender" {
  count = var.targets.postgresql ? 1 : 0

  type        = "Microsoft.DBforPostgreSQL/flexibleServers/advancedThreatProtectionSettings@${local.postgresql.atp_api_version}"
  resource_id = "${azurerm_postgresql_flexible_server.this[0].id}/advancedThreatProtectionSettings/Default"

  body = {
    properties = {
      state = "Enabled"
    }
  }

  # 適用後の値を output で確認できるように読み戻す
  response_export_values = ["properties.state"]

  depends_on = [
    azurerm_security_center_subscription_pricing.this,
    azurerm_postgresql_flexible_server_active_directory_administrator.this,
  ]
}
