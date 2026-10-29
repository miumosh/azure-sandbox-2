# ============================================================================
# 出力値
# - SSH 秘密鍵 / 通知先メールアドレスなどの機微情報は出力しない
# ============================================================================
output "resource_group_name" {
  description = "検証用リソースグループ名"
  value       = azurerm_resource_group.this.name
}

output "vm_name" {
  description = "監視対象 VM 名"
  value       = azurerm_linux_virtual_machine.this.name
}

output "log_analytics_workspace_name" {
  description = "送信先 Log Analytics ワークスペース名"
  value       = azurerm_log_analytics_workspace.this.name
}

output "log_analytics_workspace_customer_id" {
  description = "az monitor log-analytics query の --workspace に渡すワークスペース ID (GUID)"
  value       = azurerm_log_analytics_workspace.this.workspace_id
}

output "data_collection_rule_id" {
  description = "VM に関連付けた DCR のリソース ID"
  value       = azurerm_monitor_data_collection_rule.this.id
}

output "verify_ama_command" {
  description = "VM 内で AMA のプロセスと rsyslog 転送設定を確認するコマンド"
  value       = "az vm run-command invoke -g ${azurerm_resource_group.this.name} -n ${azurerm_linux_virtual_machine.this.name} --command-id RunShellScript --scripts 'systemctl is-active azuremonitoragent; ls /etc/rsyslog.d/; tail -n 3 ${local.app_log.directory}/${local.app_log.file_name}' --query 'value[0].message' -o tsv"
}

output "generate_error_logs_command" {
  description = "アラート確認用に Syslog (user.err) とアプリログ (ERROR) を 1 行ずつ書き込むコマンド"
  value       = "az vm run-command invoke -g ${azurerm_resource_group.this.name} -n ${azurerm_linux_virtual_machine.this.name} --command-id RunShellScript --scripts 'logger -p user.err \"test error from logger\"; echo \"$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR something failed in sampleapp\" >> ${local.app_log.directory}/${local.app_log.file_name}' --query 'value[0].message' -o tsv"
}

output "query_logs_command" {
  description = "取り込まれた Syslog / アプリログを確認するコマンド (取り込みまで 5〜10 分程度かかる)"
  value       = "az monitor log-analytics query -w ${azurerm_log_analytics_workspace.this.workspace_id} --analytics-query \"union (Syslog | project TimeGenerated, Table='Syslog', Computer, Level=SeverityLevel, Message=SyslogMessage), (${local.app_log.table_name} | project TimeGenerated, Table='${local.app_log.table_name}', Computer, Level, Message) | where TimeGenerated > ago(30m) | top 20 by TimeGenerated desc\" -o table"
}
