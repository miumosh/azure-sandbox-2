# ============================================================
# B 側 VNet / サブネット
#   - pe-subnet : 取り込み先 ACR の Private Endpoint 用
#   - vm-subnet : Runner VM 用
# ============================================================
resource "azurerm_virtual_network" "vnet" {
  name                = "cross-sub-pull-b-vnet"
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

resource "azurerm_subnet" "vm" {
  name                 = "vm-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = var.vm_subnet_prefix
}
