# ============================================================
# AKS Cluster
# SKU: Standard / CNI Overlay / OIDC + Workload Identity
# ============================================================
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "certdirect-aks"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  dns_prefix          = "certdirect-aks"
  sku_tier            = "Standard"

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  default_node_pool {
    name           = "systempool"
    node_count     = 1
    vm_size        = "Standard_D2s_v3"
    vnet_subnet_id = azurerm_subnet.aks.id

    # 省略すると Azure 側が既定値 (max_surge=10%) を返し、provider がそれを
    # 消そうとして plan が毎回 "1 to change" になる (恒久 diff)。
    # Azure の既定値を明示して差分を消す。
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "10.100.0.0/16"
    dns_service_ip      = "10.100.0.10"
  }
}
