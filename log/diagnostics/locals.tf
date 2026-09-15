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
  prefix   = "subdiag"
  suffix   = random_string.suffix.result

  tags = {
    project = "log-diagnostics"
    env     = "sandbox"
  }

  # ---- 受け皿の Log Analytics ワークスペース ------------------------------
  # Activity Log は宛先が LAW でも Storage でも Event Hub でも良いが、
  # KQL で中身を確認したいので LAW にする。
  # 出力先テーブルは常に AzureActivity 固定 (後述の log_analytics_destination_type 参照)。
  law = {
    name = "law-${local.prefix}-${local.suffix}"
    sku  = "PerGB2018"
  }

  # ---- 診断設定 -----------------------------------------------------------
  # 名前はサブスクリプション内で一意。1 サブスクリプションあたり最大 5 件まで。
  diagnostic_setting_name = "diag-activitylog-${local.suffix}"
}
