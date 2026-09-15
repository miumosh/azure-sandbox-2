output "source_acr_name" {
  description = "ソース ACR 名"
  value       = azurerm_container_registry.source.name
}

output "source_acr_login_server" {
  description = "ソース ACR のログインサーバー (例: xxx.azurecr.io)"
  value       = azurerm_container_registry.source.login_server
}

output "source_acr_id" {
  description = "ソース ACR の Resource ID (az acr import の --registry に渡す)"
  value       = azurerm_container_registry.source.id
}
