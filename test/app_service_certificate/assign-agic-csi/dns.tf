# ===========================================================================
# 公開検証用の DNS A レコード
#   www.azure-app-service-cert-check.example.com → 方式B の AppGW Public IP
#
# 【なぜ www 側なのか】
# 方式A (assign-appgw-direct) が既に
#   azure-app-service-cert-check.example.com → 方式A の AppGW
# を持っているため、同名だと衝突する。
#
# cert/ が発行した証明書は SAN を 2 件持つ:
#   DNS:azure-app-service-cert-check.example.com        ← 方式A
#   DNS:www.azure-app-service-cert-check.example.com    ← 方式B (ここ)
# (App Service Certificate の Standard SKU は www 付きを自動で SAN に含める)
#
# → 同じ 1 枚の証明書のまま、方式A を削除せずに両方式を同時に公開検証できる。
#   TLS のホスト名不一致も起きない (SAN に含まれているため)。
#
# 【一致していること】
#   1. 証明書の SAN         … www.azure-app-service-cert-check.example.com
#   2. Ingress の host/tls  … k8s/ingress.yaml
#   3. この A レコード       … var.dns_record_name + "." + var.dns_zone_name
# ===========================================================================
data "azurerm_dns_zone" "root" {
  name                = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group_name
}

resource "azurerm_dns_a_record" "appgw" {
  name                = var.dns_record_name # "www.azure-app-service-cert-check" (多ラベル名)
  zone_name           = data.azurerm_dns_zone.root.name
  resource_group_name = data.azurerm_dns_zone.root.resource_group_name
  ttl                 = 60

  # AppGW の Public IP は allocation_method = "Static" なので値は変わらない
  records = [azurerm_public_ip.appgw.ip_address]
}
