# ============================================================================
# key_vault モジュール 入力変数
# ============================================================================
variable "key_vault_name" {
  description = "Key Vault 名 (グローバル一意・3-24 文字)"
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "sku_name" {
  type    = string
  default = "standard"
}

variable "rbac_authorization_enabled" {
  description = "アクセスポリシーではなく RBAC で権限管理するか"
  type        = bool
  default     = true
}

variable "purge_protection_enabled" {
  type    = bool
  default = false
}

variable "soft_delete_retention_days" {
  type    = number
  default = 7
}

# ---- 閉域化の要となる設定 --------------------------------------------------
variable "public_network_access_enabled" {
  description = <<-EOT
    パブリックネットワークからのアクセス可否。

    重要: Key Vault では publicNetworkAccess = Disabled にすると
    networkAcls (ip_rules / bypass = AzureServices) は一切評価されない。
    「信頼された Azure サービス」の bypass も効かなくなるため、
    Deny + bypass と public 無効は挙動が別物になる。
  EOT
  type        = bool
  default     = true
}

variable "network_acls" {
  description = <<-EOT
    networkAcls ブロック。null の場合はブロック自体を作らない。
    public_network_access_enabled = true のときのみ意味を持つ。
  EOT
  type = object({
    default_action             = optional(string, "Deny")
    bypass                     = optional(string, "AzureServices")
    ip_rules                   = optional(list(string), [])
    virtual_network_subnet_ids = optional(list(string), [])
  })
  default = null
}

# ---- Private Endpoint ------------------------------------------------------
variable "create_private_endpoint" {
  description = "Key Vault の Private Endpoint (サブリソース vault) を作成するか"
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = "Private Endpoint を配置するサブネット ID"
  type        = string
  default     = null

  validation {
    condition     = !var.create_private_endpoint || var.private_endpoint_subnet_id != null
    error_message = "create_private_endpoint = true の場合は private_endpoint_subnet_id を指定してください。"
  }
}

variable "private_dns_zone_ids" {
  description = "PE の DNS Zone Group に紐付ける privatelink.vaultcore.azure.net のゾーン ID"
  type        = list(string)
  default     = []
}
