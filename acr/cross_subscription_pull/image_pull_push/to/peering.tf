# ============================================================
# VNet ピアリング (B ⇄ A)
# ピアリングは双方向に 2 つ必要。循環依存を避けるため両方を to 側で作成する
# (A 側は alias provider "src" 経由)。
# ============================================================
resource "azurerm_virtual_network_peering" "b_to_a" {
  name                      = "peer-b-to-a"
  resource_group_name       = azurerm_resource_group.rg.name
  virtual_network_name      = azurerm_virtual_network.vnet.name
  remote_virtual_network_id = var.source_vnet_id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "a_to_b" {
  provider                  = azurerm.src
  name                      = "peer-a-to-b"
  resource_group_name       = var.source_rg_name
  virtual_network_name      = var.source_vnet_name
  remote_virtual_network_id = azurerm_virtual_network.vnet.id
  allow_forwarded_traffic   = true
}
