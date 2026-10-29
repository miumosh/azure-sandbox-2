# ============================================================================
# リソースグループ / 実行ユーザー情報
#
# フローログリソース (Microsoft.Network/networkWatchers/flowLogs) は Network Watcher の子なので
# この RG ではなく Network Watcher の RG (既定 NetworkWatcherRG) に作られる。
# ============================================================================
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}
