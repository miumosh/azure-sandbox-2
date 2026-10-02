# ============================================================================
# 検証対象: AKS クラスターのノードプールの Availability Zone 構成
#
# 検証の流れ
#   1. system_zones = ["1","2"] / user_zones = null で apply (初期状態)
#   2. ZRS ディスクの PVC を使う Pod を user プールに置き、書き込みを続けさせる
#   3. 両方を ["1","2","3"] に変えて plan -> in-place update と表示されるか確認
#   4. apply 中のノード / Pod / PV / ディスクを観測し、実際は何が起きたかを記録する
# ============================================================================
resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = local.cluster_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = local.cluster_name
  kubernetes_version  = local.kubernetes_version
  sku_tier            = "Free"

  default_node_pool {
    name       = local.system_pool.name
    vm_size    = local.system_pool.vm_size
    node_count = local.system_pool.node_count

    # 検証の主役 1。azurerm では ForceNew ではなく「rotation で更新する属性」に分類されている。
    zones = var.system_zones

    temporary_name_for_rotation = var.use_temporary_name_for_rotation ? local.system_pool.temporary_name_for_rotation : null

    only_critical_addons_enabled = true

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
  }

  tags = local.tags
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = local.user_pool.name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = local.user_pool.vm_size
  node_count            = local.user_pool.node_count
  mode                  = "User"

  # 検証用 Pod の nodeSelector に使う。agentpool ラベルは rotation 中の一時プールで
  # "usertmp" に変わってしまうため、一時プールにも引き継がれる独自ラベルで選ぶ。
  node_labels = {
    workload = "zrs-test"
  }

  # 検証の主役 2。4.16.0 未満は ForceNew (replace) だったが、4.16.0 以降は rotation で更新する。
  zones = var.user_zones

  temporary_name_for_rotation = var.use_temporary_name_for_rotation ? local.user_pool.temporary_name_for_rotation : null

  upgrade_settings {
    max_surge = "10%"
  }

  tags = local.tags
}
