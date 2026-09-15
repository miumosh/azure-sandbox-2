
# ============================================================================
# Outputs (hub-subscription / 利用者へ共有する値)
# ============================================================================
output "spoke_vnet_id" {
  description = "Spoke VNet のリソース ID (Hub 側のピアリングに使用)"
  value       = module.network.vnet_id
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "subscription_id" {
  description = "Spoke サブスクリプション ID (CLI コマンドの --subscription 用)"
  value       = var.subscription_id
}

output "psql_server_id" {
  description = "PostgreSQL サーバーのリソース ID (ADF Managed Private Endpoint 接続先)"
  value       = module.postgresql.id
}

output "psql_server_name" {
  value = module.postgresql.name
}

output "psql_fqdn" {
  value = module.postgresql.fqdn
}

output "psql_database_name" {
  value = module.postgresql.database_name
}

output "psql_admin_login" {
  value = module.postgresql.administrator_login
}

output "aks_cluster_name" {
  value = module.aks.name
}

output "aks_kube_config" {
  value     = module.aks.kube_config_raw
  sensitive = true
}

output "aks_kubelet_object_id" {
  description = "AKS の kubelet マネージドID object_id (Hub ACR の AcrPull 付与に使用)"
  value       = module.aks.kubelet_object_id
}

output "function_app_name" {
  value = module.function_app.name
}

output "function_app_default_hostname" {
  value = module.function_app.default_hostname
}

output "function_app_base_url" {
  description = "AKS クライアントの FUNCTIONS_BASE_URL に設定する値"
  value       = module.function_app.base_url
}

output "function_default_key" {
  description = "AKS クライアントが x-functions-key に設定する Function キー (default host key)"
  value       = module.function_app.default_key
  sensitive   = true
}

output "function_principal_id" {
  description = "Function の SystemAssigned マネージドID (PostgreSQL のロール付与に使用)"
  value       = module.function_app.principal_id
}
