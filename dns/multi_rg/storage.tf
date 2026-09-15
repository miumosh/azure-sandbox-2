# ============================================================================
# Private Endpoint の題材となる Storage Account (RG1 / RG2 に 1 つずつ)
# - public を無効化し、PE + Private DNS の名前解決に完全に依存させる。
# - Terraform からデータ面 (コンテナ作成等) は触らないので public 無効で apply できる。
# ============================================================================
resource "azurerm_storage_account" "this" {
  for_each = local.storage_accounts

  name                = each.value.name
  resource_group_name = azurerm_resource_group.this[each.key].name
  location            = azurerm_resource_group.this[each.key].location

  account_tier             = "Standard"
  account_replication_type = "LRS"

  public_network_access_enabled   = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  tags = local.tags
}

# ----------------------------------------------------------------------------
# Private Endpoint
# - それぞれ自分の RG / VNet の PE サブネットに配置する。
# - private_dns_zone_group により、PE の A レコードが「同じ RG のゾーン」へ
#   自動登録される。ここが「同名ゾーンが 2 つある」状態の作られ方の中心。
# ----------------------------------------------------------------------------
resource "azurerm_private_endpoint" "this" {
  for_each = local.storage_accounts

  name                = "pe-${each.value.name}-blob"
  resource_group_name = azurerm_resource_group.this[each.key].name
  location            = azurerm_resource_group.this[each.key].location
  subnet_id           = azurerm_subnet.this[each.key].id

  private_service_connection {
    name                           = "psc-${each.value.name}-blob"
    private_connection_resource_id = azurerm_storage_account.this[each.key].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.this[each.key].id]
  }

  tags = local.tags
}
