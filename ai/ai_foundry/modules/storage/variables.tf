# ============================================================================
# storage モジュール 入力変数
# ============================================================================
variable "storage_account_name" {
  description = "Storage Account 名 (グローバル一意・小文字英数 3-24 文字)"
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---- Storage Account 本体 --------------------------------------------------
variable "account_tier" {
  type    = string
  default = "Standard"
}

variable "account_replication_type" {
  description = "LRS / ZRS / GRS / RAGRS / GZRS / RAGZRS"
  type        = string
  default     = "LRS"
}

variable "account_kind" {
  type    = string
  default = "StorageV2"
}

variable "public_network_access_enabled" {
  description = <<-EOT
    パブリックネットワークからのアクセス可否。
    false にすると Private Endpoint 経由のみになるが、terraform 実行端末から
    データ面 (コンテナ / blob 作成) に到達できなくなる点に注意。
  EOT
  type        = bool
  default     = true
}

variable "shared_access_key_enabled" {
  description = "共有キー認証の可否。false にすると Entra ID 認証のみになる"
  type        = bool
  default     = true
}

variable "allow_nested_items_to_be_public" {
  type    = bool
  default = false
}

variable "cross_tenant_replication_enabled" {
  type    = bool
  default = false
}

variable "min_tls_version" {
  type    = string
  default = "TLS1_2"
}

variable "blob_properties" {
  description = <<-EOT
    blob_properties ブロック。null の場合はブロック自体を作らない。
    CORS はモジュール管理外 (main.tf の lifecycle 参照)。
  EOT
  type = object({
    versioning_enabled           = optional(bool, true)
    change_feed_enabled          = optional(bool, false)
    last_access_time_enabled     = optional(bool, false)
    delete_retention_policy_days = optional(number)
  })
  default = null
}

variable "network_rules" {
  description = "network_rules ブロック。null の場合はブロック自体を作らない (= 既定の Allow)"
  type = object({
    default_action             = optional(string, "Deny")
    bypass                     = optional(list(string), ["AzureServices"])
    ip_rules                   = optional(list(string), [])
    virtual_network_subnet_ids = optional(list(string), [])
  })
  default = null
}

variable "container_names" {
  description = "作成する Blob コンテナ名の一覧"
  type        = list(string)
  default     = []
}

variable "enable_static_website" {
  type    = bool
  default = false
}

variable "static_website_index_document" {
  type    = string
  default = "index.html"
}

variable "static_website_error_404_document" {
  type    = string
  default = "index.html"
}

# ---- Private Endpoint / Private DNS Zone -----------------------------------
variable "private_endpoints" {
  description = <<-EOT
    作成する Private Endpoint の一覧。
    type はサブリソース名 (blob / file / queue / table / web / dfs) を指定する。
  EOT
  type = list(object({
    type      = string
    subnet_id = string
  }))
  default = []

  validation {
    condition = alltrue([
      for pe in var.private_endpoints :
      contains(["blob", "file", "queue", "table", "web", "dfs"], pe.type)
    ])
    error_message = "private_endpoints[].type は blob / file / queue / table / web / dfs のいずれかを指定してください。"
  }
}

variable "create_private_dns_zone" {
  description = <<-EOT
    Private DNS Zone をこのモジュールで作成するか。
    同一 RG 内で複数の Storage Account を扱う場合、ゾーン名が重複するため
    2 つ目以降は false にして private_dns_zone_ids で既存ゾーンを渡すこと。
  EOT
  type        = bool
  default     = true
}

variable "private_dns_zone_ids" {
  description = "create_private_dns_zone = false のとき使う既存ゾーン ID。key はサブリソース名 (blob 等)"
  type        = map(string)
  default     = {}
}

variable "private_dns_zone_virtual_network_ids" {
  description = "Private DNS Zone にリンクする VNet。key はリンク識別子、value は VNet の ID"
  type        = map(string)
  default     = {}
}
