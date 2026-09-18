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
  description = "Hub のシステム割り当てマネージド ID (Key Vault へのアクセス主体)"
  value       = azurerm_ai_foundry.this.identity[0].principal_id
}

output "ai_foundry_discovery_url" {
  value = azurerm_ai_foundry.this.discovery_url
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

output "private_endpoint_id" {
  value = one(azurerm_private_endpoint.hub[*].id)
}

output "private_endpoint_ip_address" {
  value = one(azurerm_private_endpoint.hub[*].private_service_connection[0].private_ip_address)
}
