# ============================================================================
# VNet / Subnet / NSG
# ============================================================================
resource "azurerm_virtual_network" "this" {
  name                = local.vnet.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  address_space       = local.vnet.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "firewall" {
  name                 = local.subnets.firewall.name
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnets.firewall.prefix]
}

# Basic SKU のときのみ必要 (Standard/Premium で強制トンネルしない場合は不要)
resource "azurerm_subnet" "firewall_mgmt" {
  count = local.firewall_needs_mgmt_subnet ? 1 : 0

  name                 = local.subnets.fw_mgmt.name
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnets.fw_mgmt.prefix]
}

resource "azurerm_subnet" "vm" {
  name                 = local.subnets.vm.name
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnets.vm.prefix]
}

# ----------------------------------------------------------------------------
# VM サブネットの NSG
#
# ルートテーブルが「どこを通すか」を決めるのに対し、NSG は「何を通すか」。
# インバウンドは Public IP に直接届くので、送信元 = クライアントの Public IP
# のまま NSG に評価される (Firewall を挟まないため IP マスクされない)。
# ----------------------------------------------------------------------------
resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${local.vm.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags
}

resource "azurerm_network_security_rule" "allow_service_inbound" {
  name                        = "AllowServiceFromClients"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.vm.name

  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = tostring(var.service_port)
  source_address_prefixes    = values(var.inbound_clients)
  destination_address_prefix = local.subnets.vm.prefix
}

resource "azurerm_network_security_rule" "allow_ssh_inbound" {
  count = var.allow_ssh_from_clients ? 1 : 0

  name                        = "AllowSshFromClients"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.vm.name

  priority                   = 110
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "22"
  source_address_prefixes    = values(var.inbound_clients)
  destination_address_prefix = local.subnets.vm.prefix
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}
