output "name" {
  value = azurerm_data_factory.this.name
}

output "principal_id" {
  description = "ADF の SystemAssigned マネージドID (PostgreSQL のロール付与に使用)"
  value       = azurerm_data_factory.this.identity[0].principal_id
}
