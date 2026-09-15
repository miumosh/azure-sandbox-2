# ============================================================
# B 側 VNet を「A 側の共有 Private DNS ゾーン」へリンク
# ------------------------------------------------------------
# ゾーン本体は A (from) に存在するため、このリンク resource は alias provider "src"
# (= サブスク A) で作成する。これにより Runner VM が A・B 両 ACR の login server を
# 私設 IP で名前解決できる。
# ============================================================
resource "azurerm_private_dns_zone_virtual_network_link" "b" {
  provider              = azurerm.src
  name                  = "link-b-vnet"
  resource_group_name   = var.source_rg_name
  private_dns_zone_name = "privatelink.azurecr.io"
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}
