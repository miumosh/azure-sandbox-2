# ===========================================================================
# cert_source = "app_service_order"
#   App Service Certificate を購入注文し、ARM で KV に紐付ける (有料・ドメイン検証要)。
# ===========================================================================

# 1. 証明書の注文 (この時点では Pending。DNS 検証完了で Issued)
resource "azurerm_app_service_certificate_order" "this" {
  count = var.cert_source == "app_service_order" ? 1 : 0

  name                = var.cert_order_name
  resource_group_name = azurerm_resource_group.this.name
  location            = "global"

  distinguished_name = "CN=${var.common_name}"
  product_type       = var.product_type
  validity_in_years  = 1
  key_size           = 2048
  auto_renew         = false

  # 【ハマりどころ】発行後、API は validity_in_years に 0 を返す
  # (実際に GoDaddy が発行した証明書は 1 年ではなく約 6.5 ヶ月だった)。
  # そのため config の 1 と差分が出続け、plan が毎回 "1 to change" になる。
  # 有料の証明書オーダーに PATCH を打ちたくないので無視する。
  lifecycle {
    ignore_changes = [validity_in_years]
  }
}

# 2. 注文を KV に紐付け (azurerm ネイティブ非対応のため ARM デプロイで代替)
resource "azurerm_resource_group_template_deployment" "bind_to_kv" {
  count = var.cert_source == "app_service_order" ? 1 : 0

  name                = "bind-cert-order-to-kv"
  resource_group_name = azurerm_resource_group.this.name
  deployment_mode     = "Incremental"

  template_content = jsonencode({
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    resources = [
      {
        type       = "Microsoft.CertificateRegistration/certificateOrders/certificates"
        apiVersion = "2023-12-01"
        name       = "${azurerm_app_service_certificate_order.this[0].name}/${var.key_vault_secret_name}"
        location   = "global"
        properties = {
          keyVaultId         = azurerm_key_vault.this.id
          keyVaultSecretName = var.key_vault_secret_name
        }
      }
    ]
  })

  # KV への書き込み権限が付く前に紐付けると、後で証明書が KV に落ちてこない。
  # 必ず access policy → 紐付け の順にする。
  depends_on = [
    azurerm_key_vault_access_policy.certificate_registration_rp,
    azurerm_key_vault_access_policy.appservice_rp,
  ]
}
