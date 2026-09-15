# ============================================================================
# Private DNS Zone (この構成の本体)
# ----------------------------------------------------------------------------
# PE は「Private な宛先を用意する装置」であって「Private を強制する装置」ではない。
# 実際に Private を通るかはクライアントの名前解決で決まるため、
#   (1) 引かれるホスト名に対応するゾーンがあること
#   (2) そのゾーンが呼び出し元の VNet にリンクされていること
# の 2 つが揃って初めて閉域経路が成立する。
#
# 同一 RG 内で同名ゾーンは 1 つしか作れないため、ここで一元的に作って
# 各 Private Endpoint へ ID を配る。
# ============================================================================
resource "azurerm_private_dns_zone" "this" {
  for_each = local.private_dns_zone_names

  name                = each.value
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# ゾーン × リンク先 VNet を 1 段の map に平坦化する。
# 別 VNet のワークロード (AKS 等) から呼ぶ場合は
# local.private_dns_zone_vnet_links に追加すること。peering だけでは名前解決は伝播しない。
locals {
  dns_zone_links = merge([
    for zone_key, _ in local.private_dns_zone_names : {
      for link_key, vnet_id in local.private_dns_zone_vnet_links :
      "${zone_key}.${link_key}" => {
        zone_key           = zone_key
        link_key           = link_key
        virtual_network_id = vnet_id
      }
    }
  ]...)
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.dns_zone_links

  name                  = "pdzvnl-${each.value.zone_key}-${each.value.link_key}"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.zone_key].name
  virtual_network_id    = each.value.virtual_network_id
  registration_enabled  = false
  tags                  = local.tags
}
