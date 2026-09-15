# ===========================================================================
# 公開検証用の DNS A レコード
#   azure-app-service-cert-check.example.com → AppGW の Public IP
#
# これにより --resolve や /etc/hosts を使わず、ローカル PC から素の curl / ブラウザで
# 実運用と同じ経路の HTTPS 検証ができる (証明書のチェーン検証まで通ることが合格条件)。
#
# 【一致していること】次の 3 つの FQDN は必ず揃える:
#   1. 証明書の CN            … cert/ の var.common_name
#   2. Ingress の host        … k8s/ingress.yaml の spec.rules[].host
#   3. この A レコードの FQDN … var.dns_record_name + "." + var.dns_zone_name
#
# 【補足】証明書の「発行」自体にこの A レコードは不要だった。
# App Service Certificate の DNS TXT 検証はドメイン所有の証明であり、
# 対象ホストが名前解決する必要はない (TXT はルート @ に置く)。cert/README.md 参照。
# ここで A レコードが要るのは、あくまで「発行済み証明書を公開経路で使う」ため。
# ===========================================================================
data "azurerm_dns_zone" "root" {
  name                = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group_name
}

resource "azurerm_dns_a_record" "appgw" {
  name                = var.dns_record_name
  zone_name           = data.azurerm_dns_zone.root.name
  resource_group_name = data.azurerm_dns_zone.root.resource_group_name
  ttl                 = 60 # 検証中は短く (作り直し時の伝播待ちを減らす)

  # AppGW の Public IP は allocation_method = "Static" なので値は変わらない
  records = [azurerm_public_ip.appgw.ip_address]
}
