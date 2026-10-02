# ============================================================================
# 出力値 (検証スクリプトが参照する)
# ============================================================================
output "resource_group_name" {
  description = "検証用リソースグループ名"
  value       = azurerm_resource_group.this.name
}

output "cluster_name" {
  description = "AKS クラスター名"
  value       = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group" {
  description = "ノード (VMSS) とマネージドディスクが置かれる MC_ リソースグループ"
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "system_zones" {
  description = "Terraform が認識している既定ノードプールの zones"
  value       = azurerm_kubernetes_cluster.this.default_node_pool[0].zones
}

output "user_zones" {
  description = "Terraform が認識しているユーザーノードプールの zones"
  value       = azurerm_kubernetes_cluster_node_pool.user.zones
}
