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
  type    = string
  default = "LRS"
}

variable "account_kind" {
  type    = string
  default = "StorageV2"
}

variable "public_network_access_enabled" {
  description = <<-EOT
    パブリックネットワークからのアクセス可否。
    本検証では「Key Vault の閉域化だけを変数にする」ため、Storage は
    既定で public のままにしている (Storage 側の到達性を交絡要因にしない)。
  EOT
  type        = bool
  default     = true
}

variable "shared_access_key_enabled" {
  description = <<-EOT
    共有キー認証の可否。
    SAS (authType = SAS) の発行には共有キーが必要なため、本検証では true 必須。
  EOT
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
  type = object({
    versioning_enabled           = optional(bool, true)
    change_feed_enabled          = optional(bool, false)
    last_access_time_enabled     = optional(bool, false)
    delete_retention_policy_days = optional(number)
  })
  default = null
}

variable "network_rules" {
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

# ---- Private Endpoint ------------------------------------------------------
variable "private_endpoints" {
  description = "作成する Private Endpoint の一覧 (type はサブリソース名)"
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

variable "private_dns_zone_ids" {
  description = "サブリソース名 (blob / file ...) => Private DNS Zone ID。ルートで作成したゾーンを渡す"
  type        = map(string)
  default     = {}
}
