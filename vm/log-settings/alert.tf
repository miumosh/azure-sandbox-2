# ============================================================================
# ログ検索アラート
#
# - アプリログに ERROR が出たら発報
# - Syslog に err 以上が出たら発報
# 通知先 (アクショングループのメール) は terraform.tfvars の alert_email_addresses で指定する。
#
# 取り込み遅延への対策:
#   ログ検索アラートの評価ウィンドウは TimeGenerated 基準。アプリログは DCR の変換で TimeGenerated を
#   ログ行の時刻に置き換えているため、取り込みが数分遅れるとウィンドウの外に落ちて発報しない
#   (実機で 8 分遅れて取り込まれたバッチがあり、PT5M のウィンドウでは拾えなかった)。
#   そこで検索範囲は query_time_range_override で広く取り、クエリ内で ingestion_time() で絞って
#   「直近 5 分に取り込まれたレコード」を数える。
# ============================================================================
resource "azurerm_monitor_action_group" "this" {
  count = length(var.alert_email_addresses) > 0 ? 1 : 0

  name                = local.action_group.name
  resource_group_name = azurerm_resource_group.this.name
  short_name          = local.action_group.short_name

  dynamic "email_receiver" {
    for_each = var.alert_email_addresses
    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }

  tags = local.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "app_error" {
  name                = "alert-app-error-${local.suffix}"
  display_name        = "sampleapp ERROR log"
  description         = "SampleApp_CL に Level = ERROR の行が 1 件以上取り込まれた"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  scopes              = [azurerm_log_analytics_workspace.this.id]
  severity            = 2

  evaluation_frequency      = "PT5M"
  window_duration           = "PT5M"
  query_time_range_override = "PT1H"

  criteria {
    query                   = <<-KQL
      ${local.app_log.table_name}
      | where ingestion_time() > ago(5m)
      | where Level == "ERROR"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    # VM ごとに別のアラートとして扱う
    dimension {
      name     = "Computer"
      operator = "Include"
      values   = ["*"]
    }
  }

  auto_mitigation_enabled = true

  dynamic "action" {
    for_each = azurerm_monitor_action_group.this
    content {
      action_groups = [action.value.id]
    }
  }

  depends_on = [azurerm_log_analytics_workspace_table_custom_log.app]

  tags = local.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "syslog_error" {
  name                = "alert-syslog-error-${local.suffix}"
  display_name        = "syslog err or higher"
  description         = "Syslog に重要度 err 以上のメッセージが 1 件以上取り込まれた"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  scopes              = [azurerm_log_analytics_workspace.this.id]
  severity            = 2

  evaluation_frequency      = "PT5M"
  window_duration           = "PT5M"
  query_time_range_override = "PT1H"

  criteria {
    query                   = <<-KQL
      Syslog
      | where ingestion_time() > ago(5m)
      | where SeverityLevel in ("${join("\", \"", local.syslog_error_levels)}")
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    dimension {
      name     = "Computer"
      operator = "Include"
      values   = ["*"]
    }
  }

  auto_mitigation_enabled = true

  dynamic "action" {
    for_each = azurerm_monitor_action_group.this
    content {
      action_groups = [action.value.id]
    }
  }

  tags = local.tags
}
