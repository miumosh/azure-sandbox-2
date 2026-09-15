# ============================================================
# A 側 VNet / サブネット
# ソース ACR の Private Endpoint を配置する。B 側 VNet とピアリングする。
# ============================================================
resource "azurerm_virtual_network" "vnet" {
  name                = "cross-sub-pull-a-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = var.vnet_address_space
}

resource "azurerm_subnet" "pe" {
  name                 = "pe-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.pe_subnet_prefix
}
