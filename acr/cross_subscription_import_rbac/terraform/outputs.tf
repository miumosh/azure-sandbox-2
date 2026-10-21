output "src_acr_name" {
  description = "ソース ACR 名"
  value       = azurerm_container_registry.src.name
}

output "src_acr_id" {
  description = "ソース ACR の Resource ID (az acr import の --registry に渡す)"
  value       = azurerm_container_registry.src.id
}

output "dst_acr_name" {
  description = "取り込み先 ACR 名"
  value       = azurerm_container_registry.dst.name
}

output "dst_acr_id" {
  description = "取り込み先 ACR の Resource ID"
  value       = azurerm_container_registry.dst.id
}

output "import_command" {
  description = "オペレータが実行する import コマンド"
  value       = "az acr import --name ${azurerm_container_registry.dst.name} --subscription ${var.dst_subscription_id} --registry ${azurerm_container_registry.src.id} --source hello-world:latest --image hello-world:latest"
}
