# ============================================================================
# 出力
# ============================================================================
output "diagnostic_setting_id" {
  description = "作成したサブスクリプションレベル診断設定の Resource ID"
  value       = azurerm_monitor_diagnostic_setting.activity_log.id
}

output "enabled_categories" {
  description = "有効化した Activity Log カテゴリ"
  value       = sort(var.activity_log_categories)
}

output "log_analytics_workspace_id" {
  description = "宛先 Log Analytics ワークスペースの Resource ID"
  value       = azurerm_log_analytics_workspace.this.id
}

output "verify_setting_command" {
  description = "診断設定が意図どおり入ったかを az で確認するコマンド"
  value       = "az monitor diagnostic-settings subscription show --name ${local.diagnostic_setting_name} --query 'logs[?enabled].category' -o tsv"
}

output "verify_logs_command" {
  description = "取り込まれた Activity Log をカテゴリ別に集計する KQL 実行コマンド (反映まで数分〜十数分かかる)"
  value       = "az monitor log-analytics query -w ${azurerm_log_analytics_workspace.this.workspace_id} --analytics-query 'AzureActivity | where TimeGenerated > ago(1h) | summarize count() by Category' -o table"
}
