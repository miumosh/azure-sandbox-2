# ============================================================================
# 検証対象: Azure Cache for Redis (Premium) の Availability Zone 構成
#
# 検証の流れ
#   1. var.redis_zones = ["1"]      で apply  -> 単一ゾーンのキャッシュができる
#   2. var.redis_zones = ["1","2"]  で plan   -> zones は ForceNew なので replace になる
#   3. replace を避ける方法を CLI / REST API / ポータルで探す (research.md 参照)
# ============================================================================
resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}

resource "azurerm_redis_cache" "this" {
  name                = local.redis.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  sku_name = local.redis.sku_name
  family   = local.redis.family
  capacity = local.redis.capacity

  replicas_per_master = local.redis.replicas_per_master
  redis_version       = local.redis.redis_version
  minimum_tls_version = local.redis.minimum_tls_version

  # 検証の主役。azurerm では ForceNew 属性なので、値を変えると必ず replace される。
  #   https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/redis_cache#zones
  #   > Changing this forces a new Redis Cache to be created.
  zones = var.redis_zones

  non_ssl_port_enabled          = false
  public_network_access_enabled = true

  redis_configuration {
    maxmemory_policy = "volatile-lru"
  }

  tags = local.tags

  # --------------------------------------------------------------------------
  # 【回避策 3 を試すときだけ有効にする】
  #
  # REST API / ポータルで zonalAllocationPolicy = Automatic に変更すると、
  # Azure 側の zones は Azure が選んだ値に書き換わる。一方 azurerm プロバイダは
  # zonalAllocationPolicy を扱えない (未実装 / hashicorp/terraform-provider-azurerm#28336)
  # ため、その後の terraform plan は zones の差分を検出して replace を出し続ける。
  #
  # zones の管理を Terraform の手から離して Azure 側に委ねる、というのが下記の宣言。
  # これを入れると plan はクリーンになるが、「Terraform は zones を一切管理しない」
  # ことを意味するので、採用するかはチームの方針次第。
  #
  # lifecycle {
  #   ignore_changes = [zones]
  # }
  # --------------------------------------------------------------------------
}
