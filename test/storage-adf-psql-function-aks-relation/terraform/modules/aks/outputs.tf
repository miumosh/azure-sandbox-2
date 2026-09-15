output "name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "kube_config_raw" {
  value     = azurerm_kubernetes_cluster.this.kube_config_raw
  sensitive = true
}

output "kubelet_object_id" {
  description = "AKS の kubelet マネージドID object_id (Hub ACR の AcrPull 付与に使用)"
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}
