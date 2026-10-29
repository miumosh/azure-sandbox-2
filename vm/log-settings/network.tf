# ============================================================================
# VM 用ネットワーク
#
# パブリック IP は付けず、受信は NSG の既定ルールのみ (インターネットからは DenyAllInBound)。
# VM 内の操作 (ログの発生) は az vm run-command で行う。
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

  # AMA は *.handler.control.monitor.azure.com (DCR の取得) と
  # *.ods.opinsights.azure.com (データ送信) へ HTTPS で外向きに出る必要がある。
  # 新規 VNet のサブネットは既定でデフォルトアウトバウンドが無効なので明示的に有効にする
  # (本番では NAT Gateway / Firewall / Private Link (AMPLS) を使う)
  default_outbound_access_enabled = true
}

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
