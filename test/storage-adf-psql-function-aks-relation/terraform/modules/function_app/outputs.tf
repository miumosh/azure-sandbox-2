output "name" {
  value = azurerm_linux_function_app.this.name
}

output "default_hostname" {
  value = azurerm_linux_function_app.this.default_hostname
}

output "base_url" {
  description = "AKS クライアントの FUNCTIONS_BASE_URL に設定する値"
  value       = "https://${azurerm_linux_function_app.this.default_hostname}"
}

output "default_key" {
  description = "AKS クライアントが x-functions-key に設定する Function キー (default host key)"
  value       = data.azurerm_function_app_host_keys.this.default_function_key
  sensitive   = true
}

output "principal_id" {
  description = "Function の SystemAssigned マネージドID (PostgreSQL のロール付与に使用)"
  value       = azurerm_linux_function_app.this.identity[0].principal_id
}

output "id" {
  value = azurerm_linux_function_app.this.id
}

output "storage_account_id" {
  description = "Functions メタデータ用 Storage の ID (env 側で PE / コンテナ / RBAC を張るのに使う)"
  value       = azurerm_storage_account.this.id
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}
