# ============================================================
# 取り込み先 ACR の Private Endpoint (B 側 VNet 内)
# レコードは A 側の共有 Private DNS ゾーンへ登録する (source_dns_zone_id を参照)。
# これで A・B 両 ACR のレコードが 1 つのゾーンに集約される。
# ============================================================
resource "azurerm_private_endpoint" "acr" {
  name                = "cross-sub-pull-b-acr-pe"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "acr-psc"
    private_connection_resource_id = azurerm_container_registry.target.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr-dns-zone-group"
    private_dns_zone_ids = [var.source_dns_zone_id]
  }
}
