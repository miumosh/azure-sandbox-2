# ============================================================================
# VNet / Subnet / Peering
# ============================================================================
resource "azurerm_virtual_network" "this" {
  for_each = local.vnets

  name                = each.value.name
  resource_group_name = azurerm_resource_group.this[each.key].name
  location            = azurerm_resource_group.this[each.key].location
  address_space       = each.value.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "this" {
  for_each = local.vnets

  name                 = each.value.subnet_name
  resource_group_name  = azurerm_resource_group.this[each.key].name
  virtual_network_name = azurerm_virtual_network.this[each.key].name
  address_prefixes     = each.value.subnet_prefix
}

# ----------------------------------------------------------------------------
# フルメッシュ ピアリング
#
# ピアリングは L3 の到達性しか与えない。Private DNS の名前解決範囲は
# 「Private DNS ゾーン <-> VNet のリンク」だけで決まり、ピアリング先の VNet が
# 持つゾーンリンクを引き継ぐことはない (この検証で確認する挙動のひとつ)。
# ----------------------------------------------------------------------------
resource "azurerm_virtual_network_peering" "this" {
  for_each = local.peerings

  name                      = "peer-${each.key}"
  resource_group_name       = azurerm_resource_group.this[each.value.from].name
  virtual_network_name      = azurerm_virtual_network.this[each.value.from].name
  remote_virtual_network_id = azurerm_virtual_network.this[each.value.to].id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
