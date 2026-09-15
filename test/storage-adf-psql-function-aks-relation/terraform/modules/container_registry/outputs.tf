output "id" {
  value = azurerm_container_registry.this.id
}

output "name" {
  value = azurerm_container_registry.this.name
}

output "login_server" {
  description = "AKS Deployment のイメージ参照に使う (例: ci00acr.azurecr.io)"
  value       = azurerm_container_registry.this.login_server
}
