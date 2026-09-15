# ============================================================================
# Private DNS ゾーン (検証の中心)
# ============================================================================

# ----------------------------------------------------------------------------
# 検証 (1): 同名の Private DNS ゾーンを別 RG に作れるか
#
# Private DNS ゾーンは「RG スコープ」のリソースで、名前の一意性も RG 単位。
# したがって同一サブスクリプション内でも RG が違えば同名ゾーンを併存できる
# ("privatelink.blob.core.windows.net" が 2 つ存在する状態) — はず。
# for_each で RG1 / RG2 に同じ name のゾーンを作って実証する。
# ----------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "this" {
  for_each = local.resource_groups_with_zone

  name                = local.private_dns_zone_name
  resource_group_name = azurerm_resource_group.this[each.key].name
  tags                = merge(local.tags, { owner_rg = each.key })
}

# ----------------------------------------------------------------------------
# 検証 (3) 用の手動 A レコード
#
# PE が自動登録する A レコードはストレージ名 (= グローバル一意) なので、
# 2 ゾーンで FQDN が別々になり「同一 FQDN の解決先が食い違う」様子は見えない。
# そこで両ゾーンに同じレコード名 / 異なる IP を明示的に置き、
# VNet3 からの解決結果がリンク先ゾーンによって変わることを確認する。
#   conflict.privatelink.blob.core.windows.net
#     RG1 のゾーン -> 10.10.99.99
#     RG2 のゾーン -> 10.20.99.99
# ----------------------------------------------------------------------------
resource "azurerm_private_dns_a_record" "conflict" {
  for_each = local.conflict_records

  name                = local.conflict_record_name
  zone_name           = azurerm_private_dns_zone.this[each.key].name
  resource_group_name = azurerm_resource_group.this[each.key].name
  ttl                 = 10
  records             = [each.value]
}

# ----------------------------------------------------------------------------
# VNet リンク (固定分)
# VNet1 -> RG1 のゾーン / VNet2 -> RG2 のゾーン。自分の PE を自分で引ける状態。
# ----------------------------------------------------------------------------
resource "azurerm_private_dns_zone_virtual_network_link" "own" {
  for_each = local.resource_groups_with_zone

  name                  = "link-${each.key}-own"
  resource_group_name   = azurerm_resource_group.this[each.key].name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this[each.key].id
  registration_enabled  = false
  tags                  = local.tags
}

# ----------------------------------------------------------------------------
# 検証 (2): 同じ VNet に同名ゾーンを 2 つリンクできるか
#
# var.vm_vnet_dns_link で VNet3 (VM 側) にリンクするゾーンを切り替える。
#   "rg1"  -> RG1 のゾーンだけ
#   "rg2"  -> RG2 のゾーンだけ
#   "both" -> 両方リンクしようとする。Azure 側で拒否される想定 (これが「衝突」)
#   "none" -> リンクなし。ピアリングだけでは解決できないことの確認用
#
# リンク先ゾーンは別 RG にあるが、リンクリソース自体はゾーン側の RG に作る点に注意。
#
# rg1 <-> rg2 を 1 回の apply で入れ替えると、Terraform が旧リンクの削除と
# 新リンクの作成を並列に投げるため、削除完了前に作成が走って
# "overlapping namespaces" エラーになることがある。切り替えは switch.sh
# (none を経由する 2 段階 apply) を使うこと。
# ----------------------------------------------------------------------------
resource "azurerm_private_dns_zone_virtual_network_link" "vm_vnet" {
  for_each = local.vnet3_links

  name                  = "link-vnet3-from-${each.key}"
  resource_group_name   = azurerm_resource_group.this[each.key].name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this["rg3"].id
  registration_enabled  = false
  tags                  = local.tags
}
