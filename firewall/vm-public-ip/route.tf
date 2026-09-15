# ============================================================================
# ルートテーブル (本構成の中核)
#
# VM サブネットにだけ関連付ける。AzureFirewallSubnet には絶対に付けない
# (Firewall 自身の戻り経路がループする)。
#
# Azure のルート選択は「最長プレフィックス一致 -> 同一プレフィックスなら
# UDR > BGP > システムルート」。したがって:
#   - 0.0.0.0/0            -> Firewall  (既定)
#   - 宛先A / 宛先B         -> Internet  (より長い一致なので必ず勝つ)
#   - インバウンド元 CIDR   -> Internet  (戻りパケットを Public IP に揃える)
# ============================================================================
resource "azurerm_route_table" "vm" {
  name                = "rt-${local.subnets.vm.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  # ゲートウェイからの経路広報は使わない (誤って 0.0.0.0/0 を上書きされないように)
  bgp_route_propagation_enabled = false
}

# ---- 既定経路: すべて Firewall へ ------------------------------------------
resource "azurerm_route" "default_to_firewall" {
  name                   = "default-to-firewall"
  resource_group_name    = azurerm_resource_group.this.name
  route_table_name       = azurerm_route_table.vm.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.this.ip_configuration[0].private_ip_address
}

# ---- 迂回経路: Public IP から直接インターネットへ ---------------------------
# direct-*  : 宛先A / 宛先B へのアウトバウンド
# return-*  : インバウンドの戻り (行きと同じ Public IP から返すため)
resource "azurerm_route" "direct_to_internet" {
  for_each = local.direct_routes

  name                = each.key
  resource_group_name = azurerm_resource_group.this.name
  route_table_name    = azurerm_route_table.vm.name
  address_prefix      = each.value
  next_hop_type       = "Internet"
}

resource "azurerm_subnet_route_table_association" "vm" {
  subnet_id      = azurerm_subnet.vm.id
  route_table_id = azurerm_route_table.vm.id

  depends_on = [
    azurerm_route.default_to_firewall,
    azurerm_route.direct_to_internet,
  ]
}
