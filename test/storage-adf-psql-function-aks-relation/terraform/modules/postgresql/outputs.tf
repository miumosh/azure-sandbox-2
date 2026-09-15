output "id" {
  description = "PostgreSQL サーバーのリソース ID (ADF Managed Private Endpoint 接続先)"
  value       = azurerm_postgresql_flexible_server.this.id
}

output "name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.app.name
}

output "administrator_login" {
  value = azurerm_postgresql_flexible_server.this.administrator_login
}
