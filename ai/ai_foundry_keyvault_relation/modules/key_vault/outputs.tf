# ============================================================================
# key_vault モジュール 出力
# ============================================================================
output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "public_network_access_enabled" {
  value = azurerm_key_vault.this.public_network_access_enabled
}

output "private_endpoint_id" {
  value = one(azurerm_private_endpoint.this[*].id)
}

output "private_endpoint_ip_address" {
  value = one(azurerm_private_endpoint.this[*].private_service_connection[0].private_ip_address)
}
