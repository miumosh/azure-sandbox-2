# ============================================================================
# 出力値
# - キー / 接続文字列 / SSH 秘密鍵などの機微情報は出力しない
# ============================================================================
output "resource_group_name" {
  description = "検証用リソースグループ名"
  value       = azurerm_resource_group.this.name
}

output "storage_account_name" {
  description = "フローログ保存先ストレージアカウント名"
  value       = azurerm_storage_account.flowlog.name
}

output "storage_public_network_access" {
  description = "ストレージの publicNetworkAccess"
  value       = azurerm_storage_account.flowlog.public_network_access
}

output "flow_log_id" {
  description = "VNet フローログのリソース ID"
  value       = azurerm_network_watcher_flow_log.vnet.id
}

output "verify_storage_network_command" {
  description = "ストレージのネットワーク設定 (publicNetworkAccess / defaultAction / bypass) を確認するコマンド"
  value       = "az storage account show -n ${azurerm_storage_account.flowlog.name} --query \"{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, bypass:networkRuleSet.bypass}\" -o table"
}

output "verify_flow_log_written_command" {
  description = "フローログが書き込まれているかをコントロールプレーン経由で確認するコマンド (データプレーンが閉じていても使える)"
  value       = "az rest --method get --url \"https://management.azure.com${azurerm_storage_account.flowlog.id}/blobServices/default/containers?api-version=2023-05-01\" --query \"value[].{name:name, lastModified:properties.lastModifiedTime}\" -o table"
}
