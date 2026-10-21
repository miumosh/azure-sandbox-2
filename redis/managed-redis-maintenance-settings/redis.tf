# ============================================================================
# 検証対象: Azure Managed Redis (Microsoft.Cache/redisEnterprise) 本体
#
# 本体は azurerm で管理し、メンテナンス設定だけを maintenance.tf の azapi で上書きする
# 「ハイブリッド構成」にしてある。既存の azurerm 管理リソースに後付けする場面を想定。
# ============================================================================
resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}

resource "azurerm_managed_redis" "this" {
  name                = local.managed_redis.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  sku_name = local.managed_redis.sku_name

  default_database {
    access_keys_authentication_enabled = true
  }

  tags = local.tags
}
