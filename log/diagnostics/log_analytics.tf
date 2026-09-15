# ============================================================================
# 宛先: Log Analytics ワークスペース
# ============================================================================
resource "azurerm_log_analytics_workspace" "this" {
  name                = local.law.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  sku               = local.law.sku
  retention_in_days = var.log_analytics_retention_in_days

  # サンドボックスでの取り込み事故を防ぐための日次上限。無制限にするなら -1。
  daily_quota_gb = var.log_analytics_daily_quota_gb

  tags = local.tags
}
