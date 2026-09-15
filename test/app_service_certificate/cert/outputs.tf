# ---- 割り当て側 (assign-*) が data 参照するための共通出力 --------------------
output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "key_vault_resource_group" {
  value = azurerm_resource_group.this.name
}

output "certificate_secret_name" {
  value = var.key_vault_secret_name
}

output "certificate_secret_versionless_id" {
  description = "AppGW の ssl_certificate.key_vault_secret_id にそのまま渡せる versionless id"
  value       = "${azurerm_key_vault.this.vault_uri}secrets/${var.key_vault_secret_name}"
}

# ---- order モード向けの補助出力 --------------------------------------------
output "cert_source" {
  value = var.cert_source
}

output "cert_order_status" {
  description = "order モードの注文ステータス。Issued で KV に実体あり"
  value       = var.cert_source == "app_service_order" ? azurerm_app_service_certificate_order.this[0].status : "n/a (self_signed)"
}

output "domain_verification_token" {
  description = "order モードの DNS/HTML 検証トークン"
  value       = var.cert_source == "app_service_order" ? azurerm_app_service_certificate_order.this[0].domain_verification_token : ""
}
