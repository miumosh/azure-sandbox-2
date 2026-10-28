# ============================================================================
# 検証対象: Defender for Containers
#
# Containers はリソース単位で有効化できないため、プラン自体は defender_plans.tf の
# サブスクリプション単位 pricings で有効化する。ここでは保護対象を用意する。
#
#   - AKS : microsoft_defender ブロックで Defender センサーを明示的にデプロイする
#           (プランの自動プロビジョニング (Azure Policy) 任せだと反映まで時間がかかるため)
#   - ACR : レジストリイメージの脆弱性評価の対象
#   - LAW : Defender センサーの送信先 (センサーの必須設定)
# ============================================================================
resource "azurerm_log_analytics_workspace" "this" {
  count = var.targets.containers ? 1 : 0

  name                = local.law.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = local.law.sku
  retention_in_days   = 30
  daily_quota_gb      = local.law.daily_quota_gb

  tags = local.tags
}

resource "azurerm_container_registry" "this" {
  count = var.targets.containers ? 1 : 0

  name                = local.acr.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = local.acr.sku

  # 管理者ユーザー (固定パスワード) は使わず Entra 認証に限定する
  admin_enabled = false

  tags = local.tags
}

resource "azurerm_kubernetes_cluster" "this" {
  count = var.targets.containers ? 1 : 0

  name                = local.aks.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  dns_prefix          = local.aks.name
  sku_tier            = "Free"

  default_node_pool {
    name            = "system"
    vm_size         = local.aks.vm_size
    node_count      = local.aks.node_count
    os_disk_size_gb = local.aks.os_disk_size_gb
  }

  identity {
    type = "SystemAssigned"
  }

  # azurerm 5.x では必須ブロック。ノード自動プロビジョニング (NAP / Karpenter) は使わない
  node_provisioning_profile {
    mode = "Manual"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
  }

  # ローカルアカウント (クライアント証明書入りの admin kubeconfig) を無効化し、
  # Entra ID + Azure RBAC だけで認可する。state に静的な認証情報が残らない。
  local_account_disabled = true

  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  # Defender センサー (DaemonSet: microsoft-defender-collector-*) をデプロイする
  microsoft_defender {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this[0].id
  }

  tags = local.tags

  # プランが Standard になってからセンサーを入れる
  depends_on = [azurerm_security_center_subscription_pricing.this]
}

# 実行ユーザーが kubectl を使えるようにする (local_account_disabled のため必須)
resource "azurerm_role_assignment" "aks_cluster_admin" {
  count = var.targets.containers ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this[0].id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# AKS から ACR のイメージを pull できるようにする
resource "azurerm_role_assignment" "aks_acr_pull" {
  count = var.targets.containers ? 1 : 0

  scope                            = azurerm_container_registry.this[0].id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.this[0].kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}
