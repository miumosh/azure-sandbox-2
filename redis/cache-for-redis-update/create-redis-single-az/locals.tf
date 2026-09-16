# ============================================================================
# 設定値
# ============================================================================
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  prefix = var.name_prefix
  suffix = random_string.suffix.result

  tags = {
    project = "cache-for-redis-single-az"
    env     = "sandbox"
  }

  resource_group_name = "${local.prefix}-rg"

  # zones を明示指定できるのは Premium のみ。
  # Standard は Azure による自動割り当て (Automatic) 固定でゾーン番号を選べない。
  redis = {
    name                = "redis-${local.prefix}-${local.suffix}"
    sku_name            = "Premium"
    family              = "P"
    replicas_per_master = 1
    redis_version       = "6"
    minimum_tls_version = "1.2"
  }
}
