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
  prefix   = "redisaz"
  suffix   = random_string.suffix.result

  tags = {
    project = "cache-for-redis-zone-update"
    env     = "sandbox"
  }

  resource_group_name = "${local.prefix}-rg"

  # ---- Redis キャッシュ ---------------------------------------------------
  # zones を明示指定できるのは Premium のみ (Standard は Automatic 割り当て固定)。
  # そのため最小の Premium = P1 を使う。
  #
  # replicas_per_master を上げるとノード数が増え、指定できるゾーン数の上限も上がる。
  # 既定の 1 なら primary + replica = 2 ノード = 最大 2 ゾーン。
  redis = {
    name                = "redis-${local.prefix}-${local.suffix}"
    sku_name            = "Premium"
    family              = "P"
    capacity            = 1 # P1
    replicas_per_master = 1
    redis_version       = "6"
    minimum_tls_version = "1.2"
  }

  # in-place 変更を試すスクリプト群が使う ARM API バージョン。
  # zonalAllocationPolicy は 2024-11-01 で導入された。
  arm_api_version = "2024-11-01"
}
