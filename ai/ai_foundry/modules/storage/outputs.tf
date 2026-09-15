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

output "primary_web_endpoint" {
  value = azurerm_storage_account.this.primary_web_endpoint
}

output "identity_principal_id" {
  description = "Storage Account のシステム割り当てマネージド ID"
  value       = azurerm_storage_account.this.identity[0].principal_id
}

output "container_ids" {
  description = "コンテナ名 => リソース ID"
  value       = { for name, c in azurerm_storage_container.this : name => c.id }
}

output "private_dns_zone_ids" {
  description = <<-EOT
    サブリソース名 => Private DNS Zone ID。
    同一 RG に別 Storage Account を追加する際、そのモジュールへ
    create_private_dns_zone = false と併せて渡してゾーンを再利用する。
  EOT
  value       = local.private_dns_zone_ids
}

output "private_endpoint_ids" {
  description = "サブリソース名 => Private Endpoint ID"
  value       = { for type, pe in azurerm_private_endpoint.this : type => pe.id }
}

output "private_endpoint_ip_addresses" {
  description = "サブリソース名 => PE に割り当てられたプライベート IP"
  value       = { for type, pe in azurerm_private_endpoint.this : type => pe.private_service_connection[0].private_ip_address }
}
