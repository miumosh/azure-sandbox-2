# ============================================================
# 共有 Private DNS ゾーン (A 側に1つだけ作成)
# ------------------------------------------------------------
# A・B 両方の ACR の Private Endpoint レコードをこのゾーンに集約する。
# (1 つの VNet は同名ゾーンに 1 つしかリンクできないため、ゾーンは 1 つに集約し、
#  両 VNet をこのゾーンへリンクする。B 側 VNet のリンクは to 側で作成する)
# ============================================================
resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.rg.name
}

# A 側 VNet をゾーンへリンク
resource "azurerm_private_dns_zone_virtual_network_link" "a" {
  name                  = "link-a-vnet"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}
