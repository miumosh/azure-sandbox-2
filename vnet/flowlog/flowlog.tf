# ============================================================================
# VNet フローログ
#
# NSG フローログは 2025-06-30 以降新規作成できないため、VNet を target_resource_id にする。
# Network Watcher はサブスクリプション × リージョンで 1 つなので既存を参照し、
# フローログリソースもその RG に作る。
# 書き込み先コンテナー (insights-logs-flowlogflowevent) は Network Watcher が自動で作るため、
# Terraform からストレージのデータプレーンを操作する必要はない (= public_network_access = Disabled でも apply できる)。
# ============================================================================
data "azurerm_network_watcher" "this" {
  name                = local.network_watcher.name
  resource_group_name = local.network_watcher.resource_group_name
}

resource "azurerm_network_watcher_flow_log" "vnet" {
  name                 = local.flow_log.name
  network_watcher_name = data.azurerm_network_watcher.this.name
  resource_group_name  = data.azurerm_network_watcher.this.resource_group_name
  location             = data.azurerm_network_watcher.this.location

  target_resource_id = azurerm_virtual_network.this.id
  storage_account_id = azurerm_storage_account.flowlog.id
  enabled            = true
  version            = 2

  retention_policy {
    enabled = true
    days    = local.flow_log.retention_days
  }

  tags = local.tags
}
