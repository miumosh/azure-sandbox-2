# ============================================================================
# aks モジュール
# System-assigned MI / Azure CNI / 最小構成。Functions へは privatelink DNS 経由で
# Private Endpoint に到達する。AKS -> Function は Function キー方式 (UAMI 不使用)。
# ============================================================================
resource "azurerm_kubernetes_cluster" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.dns_prefix

  # 検証簡略化のため kubeconfig はパブリック API でアクセスする
  private_cluster_enabled = false

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name                 = "system"
    node_count           = var.node_count
    vm_size              = var.node_size
    vnet_subnet_id       = var.subnet_id
    type                 = "VirtualMachineScaleSets"
    os_disk_size_gb      = var.os_disk_size_gb
    auto_scaling_enabled = false

    # Azure 既定値を明示して plan の drift を抑止する
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip
  }

  oms_agent {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  tags = var.tags
}
