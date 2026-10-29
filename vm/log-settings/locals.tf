# ============================================================================
# 環境設定値 (locals で集中管理)
# ============================================================================
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  location = var.location
  prefix   = "vmlog"
  suffix   = random_string.suffix.result

  tags = {
    project = "vm-log-settings"
    env     = "sandbox"
  }

  resource_group_name = "rg-${local.prefix}-${local.suffix}"

  # ---- ネットワーク ----------------------------------------------------------
  vnet = {
    name          = "vnet-${local.prefix}-${local.suffix}"
    address_space = ["10.20.0.0/16"]
  }
  subnet = {
    name             = "snet-vm"
    address_prefixes = ["10.20.1.0/24"]
  }
  nsg = {
    name = "nsg-${local.prefix}-${local.suffix}"
  }

  # ---- VM --------------------------------------------------------------------
  vm = {
    name = "vm-${local.prefix}-${local.suffix}"
    # AMA (mdsd) と cloud-init を同時に動かすので 1 GiB の B1s は避ける
    size           = "Standard_B2s"
    admin_username = "azureuser"
  }

  # ---- Log Analytics ワークスペース ------------------------------------------
  law = {
    name = "law-${local.prefix}-${local.suffix}"
    sku  = "PerGB2018"
  }

  # ---- アプリログ (テキストファイル) ----------------------------------------
  app_log = {
    # VM 上のサンプルアプリが書き出すファイル。DCR の file_patterns にはワイルドカードが使える
    directory = "/var/log/sampleapp"
    file_name = "app.log"
    # カスタムテーブル名は _CL で終わる必要がある。DCR の入力ストリーム名は Custom-<テーブル名>
    table_name  = "SampleApp_CL"
    stream_name = "Custom-SampleApp_CL"
  }

  # ---- データ収集ルール ------------------------------------------------------
  dcr = {
    name = "dcr-${local.prefix}-${local.suffix}"
    # Syslog として収集するファシリティ (Ubuntu の rsyslog から AMA に転送される)
    syslog_facilities = [
      "auth", "authpriv", "cron", "daemon", "kern", "syslog", "user",
    ]
  }

  # ---- アラート --------------------------------------------------------------
  # Syslog の SeverityLevel の値。AMA 経由では err -> "error" / crit -> "critical" / warning -> "warning" になる (実機確認)。
  # 旧 Log Analytics エージェントの略記 (err / crit / emerg) も念のため残す
  syslog_error_levels = ["err", "error", "crit", "critical", "alert", "emerg", "emergency"]

  action_group = {
    name       = "ag-${local.prefix}-${local.suffix}"
    short_name = "vmlog" # 12 文字以内
  }
}
