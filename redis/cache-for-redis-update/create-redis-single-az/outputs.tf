# ============================================================================
# 出力値
# ============================================================================
output "resource_group_name" {
  description = "リソースグループ名"
  value       = azurerm_resource_group.this.name
}

output "redis_name" {
  description = "Redis キャッシュ名"
  value       = azurerm_redis_cache.this.name
}

output "redis_id" {
  description = "ARM リソース ID"
  value       = azurerm_redis_cache.this.id
}

output "redis_hostname" {
  description = <<-EOT
    接続先ホスト名。<キャッシュ名>.redis.cache.windows.net の形式で、
    キャッシュ名を変えない限り再作成しても同じ値になる。
    ただしアクセスキーは再作成で変わる点に注意 (../doc/recreation-impact.md)。
  EOT
  value       = azurerm_redis_cache.this.hostname
}

output "redis_ssl_port" {
  description = "SSL ポート"
  value       = azurerm_redis_cache.this.ssl_port
}

output "redis_zones" {
  description = "配置されている Availability Zone"
  value       = azurerm_redis_cache.this.zones
}

output "redis_primary_access_key" {
  description = "プライマリアクセスキー (再作成のたびに変わる)"
  value       = azurerm_redis_cache.this.primary_access_key
  sensitive   = true
}

output "redis_primary_connection_string" {
  description = "プライマリ接続文字列"
  value       = azurerm_redis_cache.this.primary_connection_string
  sensitive   = true
}
