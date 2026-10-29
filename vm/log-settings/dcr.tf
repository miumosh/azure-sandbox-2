# ============================================================================
# データ収集ルール (DCR) と VM への関連付け
#
# 1 つの DCR に 2 つのデータソースをまとめる:
#   - syslog   : rsyslog から AMA へ転送されたメッセージ -> Syslog テーブル
#                (Ubuntu では /var/log/messages は無く /var/log/syslog だが、
#                 AMA はファイルではなく rsyslog からの転送を受け取る)
#   - log_file : /var/log/sampleapp/*.log -> SampleApp_CL テーブル
#
# DCE (データ収集エンドポイント) はテキストログ収集でも Private Link (AMPLS) を使わない限り不要。
# ============================================================================
resource "azurerm_monitor_data_collection_rule" "this" {
  name                = local.dcr.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  description         = "Ubuntu VM の Syslog とアプリログ (テキストファイル) を Log Analytics へ送る"

  destinations {
    log_analytics {
      name                  = "law"
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
    }
  }

  # テキストファイルの入力ストリームの列定義。AMA が付与する列名・型は固定
  stream_declaration {
    stream_name = local.app_log.stream_name

    column {
      name = "TimeGenerated"
      type = "datetime"
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
  }

  data_sources {
    syslog {
      name           = "syslog"
      streams        = ["Microsoft-Syslog"]
      facility_names = local.dcr.syslog_facilities
      log_levels     = var.syslog_log_levels
    }

    log_file {
      name          = "sampleapp"
      streams       = [local.app_log.stream_name]
      file_patterns = ["${local.app_log.directory}/*.log"]
      format        = "text"

      # 行頭がこの書式のタイムスタンプで始まる行を 1 レコードの開始とみなす (複数行ログ対策)
      settings {
        text {
          record_start_timestamp_format = "ISO 8601"
        }
      }
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["law"]
  }

  # TimeGenerated は既定では AMA が読み取った時刻になるため、行頭のタイムスタンプで置き換える。
  # 変換で追加する列 (Level / Message) はカスタムテーブル側に定義済みである必要がある
  data_flow {
    streams       = [local.app_log.stream_name]
    destinations  = ["law"]
    output_stream = local.app_log.stream_name
    transform_kql = <<-KQL
      source
      | extend LogTime = todatetime(extract(@"^(\S+)", 1, RawData))
      | extend Level = extract(@"^\S+\s+(\w+)", 1, RawData)
      | extend Message = extract(@"^\S+\s+\w+\s+(.*)$", 1, RawData)
      | extend TimeGenerated = iif(isnull(LogTime), TimeGenerated, LogTime)
      | project-away LogTime
    KQL
  }

  depends_on = [azurerm_log_analytics_workspace_table_custom_log.app]

  tags = local.tags
}

resource "azurerm_monitor_data_collection_rule_association" "vm" {
  name                    = "dcra-${local.vm.name}"
  target_resource_id      = azurerm_linux_virtual_machine.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.this.id
  description             = "VM に DCR を関連付けて AMA に収集設定を配布する"
}
