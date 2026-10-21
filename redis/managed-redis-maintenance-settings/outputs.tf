# ============================================================================
# 出力値
# ============================================================================
output "resource_group_name" {
  description = "検証用リソースグループ名"
  value       = azurerm_resource_group.this.name
}

output "managed_redis_name" {
  description = "Managed Redis 名"
  value       = azurerm_managed_redis.this.name
}

output "managed_redis_id" {
  description = "Managed Redis の ARM リソース ID"
  value       = azurerm_managed_redis.this.id
}

output "maintenance_configuration" {
  description = "Azure から読み戻したメンテナンス設定 (カスタムスケジュール未設定時は null)"
  # カスタムスケジュールを解除 ([]) すると API は maintenanceConfiguration 自体を返さなくなるため try で吸収する
  value = try(azapi_update_resource.maintenance.output.properties.maintenanceConfiguration, null)
}

output "arm_api_version" {
  description = "メンテナンス設定の読み書きに使う ARM API バージョン"
  value       = local.arm_api_version
}
