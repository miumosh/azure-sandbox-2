# ===========================================================================
# cert_source = "self_signed"
#   自己署名証明書を KV に作成 (無料・即時)。
#   content_type=application/x-pkcs12 (PFX) なので AppGW / CSI がそのまま消費できる。
#   割り当て検証 (assign-*) の配管確認に使い、購入証明書を無駄撃ちしないためのモード。
# ===========================================================================
resource "azurerm_key_vault_certificate" "self_signed" {
  count = var.cert_source == "self_signed" ? 1 : 0

  name         = var.key_vault_secret_name
  key_vault_id = azurerm_key_vault.this.id

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=${var.common_name}"
      validity_in_months = 12

      key_usage = [
        "digitalSignature",
        "keyEncipherment",
      ]

      subject_alternative_names {
        dns_names = [var.common_name]
      }
    }
  }

  depends_on = [azurerm_key_vault_access_policy.me]
}
