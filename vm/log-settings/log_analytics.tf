# ============================================================================
# 送信先: Log Analytics ワークスペース + アプリログ用カスタムテーブル
#
# - Syslog は組み込みの Syslog テーブルに入るので作成不要
# - テキストファイル (アプリログ) の送信先テーブルは組み込みに無いため、
#   _CL で終わるカスタムテーブルを DCR より先に作っておく必要がある
#   (DCR 作成時に outputStream のテーブルが存在するか検証される)
# ============================================================================
resource "azurerm_log_analytics_workspace" "this" {
  name                = local.law.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  sku               = local.law.sku
  retention_in_days = var.log_analytics_retention_in_days
  daily_quota_gb    = var.log_analytics_daily_quota_gb

  tags = local.tags
}

# AMA のテキストログ収集で入ってくる列は TimeGenerated / RawData / Computer / FilePath。
# Level / Message は DCR の変換 (transform_kql) で RawData から切り出して追加する列。
resource "azurerm_log_analytics_workspace_table_custom_log" "app" {
  name              = local.app_log.table_name
  workspace_id      = azurerm_log_analytics_workspace.this.id
  plan              = "Analytics"
  retention_in_days = var.log_analytics_retention_in_days

  column {
    name = "TimeGenerated"
    type = "dateTime"
  }
  column {
    name = "RawData"
    type = "string"
  }
  column {
    name = "Computer"
    type = "string"
  }
  column {
    name = "FilePath"
    type = "string"
  }
  column {
    name = "Level"
    type = "string"
  }
  column {
    name = "Message"
    type = "string"
  }
}
