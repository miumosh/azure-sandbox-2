# ============================================================================
# storage モジュール 出力
# ============================================================================
output "storage_account_id" {
  value = azurerm_storage_account.this.id
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}

output "primary_blob_endpoint" {
  value = azurerm_storage_account.this.primary_blob_endpoint
}

output "primary_connection_string" {
  description = "SAS 発行 (data.azurerm_storage_account_sas) に使う接続文字列"
  value       = azurerm_storage_account.this.primary_connection_string
  sensitive   = true
}

output "container_ids" {
  value = { for name, c in azurerm_storage_container.this : name => c.id }
}

output "private_endpoint_ip_addresses" {
  value = { for type, pe in azurerm_private_endpoint.this : type => pe.private_service_connection[0].private_ip_address }
}
