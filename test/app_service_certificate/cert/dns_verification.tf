# ===========================================================================
# order モードの DNS TXT 検証 (Manual verification)
#   既存 Azure DNS ゾーン (rg-dns / example.com) に検証トークンを TXT 投入。
#
#   【ハマりどころ】TXT は "@" (ルートドメイン) に置く。
#   CN がサブドメイン (azure-app-service-cert-check.example.com) なので
#   サブドメイン側に TXT を置きたくなるが、それでは検証が通らない。
#   → var.dns_verification_record_name のコメント参照 (公式ドキュメント原文つき)
#
#   TXT 投入だけでは Pending のまま。ゾーンが公開伝播した後に
#   verifyDomainOwnership を叩いて CA に検証させる (README の手順参照)。
# ===========================================================================
data "azurerm_dns_zone" "root" {
  count = var.cert_source == "app_service_order" ? 1 : 0

  name                = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group_name
}

resource "azurerm_dns_txt_record" "cert_verify" {
  count = var.cert_source == "app_service_order" ? 1 : 0

  name                = var.dns_verification_record_name
  zone_name           = data.azurerm_dns_zone.root[0].name
  resource_group_name = data.azurerm_dns_zone.root[0].resource_group_name
  ttl                 = 300

  record {
    value = azurerm_app_service_certificate_order.this[0].domain_verification_token
  }
}
