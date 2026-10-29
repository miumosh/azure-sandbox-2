# ============================================================================
# フローログの対象 VNet
# ============================================================================
resource "azurerm_virtual_network" "this" {
  name                = local.vnet.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = local.vnet.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "vm" {
  name                 = local.subnet.name
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = local.subnet.address_prefixes

  # 検証用 VM がパッケージ更新などで外向き通信を行い、フローログに記録されるようにする
  # (新規 VNet のサブネットは既定でデフォルトアウトバウンドが無効)
  default_outbound_access_enabled = true
}

# 受信は既定ルールのみ (インターネットからの受信は DenyAllInBound で拒否され、拒否フローとして記録される)
resource "azurerm_network_security_group" "this" {
  name                = local.nsg.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.this.id
}
