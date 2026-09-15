# ============================================================================
# ai_foundry モジュール 出力
# ============================================================================
output "ai_foundry_id" {
  value = azurerm_ai_foundry.this.id
}

output "ai_foundry_name" {
  value = azurerm_ai_foundry.this.name
}

output "ai_foundry_identity_principal_id" {
  description = "Hub のシステム割り当てマネージド ID (Storage / Key Vault への RBAC 付与に使う)"
  value       = azurerm_ai_foundry.this.identity[0].principal_id
}

output "ai_foundry_project_id" {
  value = azurerm_ai_foundry_project.this.id
}

output "ai_foundry_project_name" {
  value = azurerm_ai_foundry_project.this.name
}

output "ai_foundry_project_identity_principal_id" {
  value = azurerm_ai_foundry_project.this.identity[0].principal_id
}

output "ai_services_id" {
  value = azurerm_cognitive_account.ai_services.id
}

output "ai_services_name" {
  value = azurerm_cognitive_account.ai_services.name
}

output "ai_services_endpoint" {
  value = azurerm_cognitive_account.ai_services.endpoint
}

output "ai_services_identity_principal_id" {
  value = azurerm_cognitive_account.ai_services.identity[0].principal_id
}

output "ai_services_primary_access_key" {
  value     = azurerm_cognitive_account.ai_services.primary_access_key
  sensitive = true
}

output "private_dns_zone_ids" {
  description = "ゾーン名 => Private DNS Zone ID"
  value       = local.private_dns_zone_ids
}

output "private_endpoint_id" {
  value = one(azurerm_private_endpoint.ai_services[*].id)
}

output "private_endpoint_ip_address" {
  description = "AI Services 用 PE のプライベート IP"
  value       = one(azurerm_private_endpoint.ai_services[*].private_service_connection[0].private_ip_address)
}
