# ============================================================================
# 出力値 (検証スクリプトが参照する)
# ============================================================================
output "resource_group_name" {
  description = "検証用リソースグループ名"
  value       = azurerm_resource_group.this.name
}

output "redis_name" {
  description = "Redis キャッシュ名"
  value       = azurerm_redis_cache.this.name
}

output "redis_id" {
  description = "Redis キャッシュの ARM リソース ID"
  value       = azurerm_redis_cache.this.id
}

output "redis_zones" {
  description = "Terraform が認識している現在のゾーン構成"
  value       = azurerm_redis_cache.this.zones
}

output "redis_hostname" {
  description = "Redis のホスト名"
  value       = azurerm_redis_cache.this.hostname
}

output "arm_api_version" {
  description = "検証スクリプトが ARM API を直接叩くときに使う API バージョン"
  value       = local.arm_api_version
}
