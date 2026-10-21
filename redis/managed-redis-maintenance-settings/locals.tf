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
  prefix   = "amrmnt"
  suffix   = random_string.suffix.result

  tags = {
    project = "managed-redis-maintenance-settings"
    env     = "sandbox"
  }

  resource_group_name = "${local.prefix}-rg"

  # ---- Managed Redis -------------------------------------------------------
  # メンテナンス設定の検証が目的なので最小 SKU (Balanced_B0) で十分。
  managed_redis = {
    name     = "amr-${local.prefix}-${local.suffix}"
    sku_name = "Balanced_B0"
  }

  # maintenanceConfiguration は 2025-08-01-preview で導入され、stable では 2026-09-01 から使える。
  # (azure-rest-api-specs: specification/redisenterprise/.../stable/2026-09-01/redisenterprise.json)
  arm_api_version = "2026-09-01"

  # API に渡す形 (MaintenanceWindow) に変換する
  maintenance_windows = [
    for w in var.maintenance_windows : {
      type         = "Weekly"
      duration     = format("PT%dH", w.duration_hours)
      startHourUtc = w.start_hour_utc
      schedule = {
        dayOfWeek = w.day_of_week
      }
    }
  ]
}
