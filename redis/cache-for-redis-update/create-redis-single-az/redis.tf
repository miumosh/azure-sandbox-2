# ============================================================================
# Premium / 単一 AZ の Azure Cache for Redis
# ============================================================================
resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_redis_cache" "this" {
  name                = local.redis.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  sku_name = local.redis.sku_name
  family   = local.redis.family
  capacity = var.capacity

  replicas_per_master = local.redis.replicas_per_master
  redis_version       = local.redis.redis_version
  minimum_tls_version = local.redis.minimum_tls_version

  # 単一 AZ 配置。
  # ★ ForceNew: この値を変えると破棄 -> 再作成になる。
  #   ゾーン数は「primary 1 + replica 1 = 2 ノード」以下という制約もある。
  #   再作成の影響範囲は ../doc/recreation-impact.md を参照。
  zones = [var.zone]

  non_ssl_port_enabled          = false
  public_network_access_enabled = true

  redis_configuration {
    maxmemory_policy = "volatile-lru"
  }

  tags = local.tags
}
