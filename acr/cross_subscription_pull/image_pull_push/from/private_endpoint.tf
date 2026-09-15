# ============================================================
# ソース ACR の Private Endpoint (A 側 VNet 内)
# private_dns_zone_group により、registry 用と data 用の A レコードが
# 共有ゾーンへ自動登録される。
# ============================================================
resource "azurerm_private_endpoint" "acr" {
  name                = "cross-sub-pull-a-acr-pe"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "acr-psc"
    private_connection_resource_id = azurerm_container_registry.source.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr-dns-zone-group"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }
}
