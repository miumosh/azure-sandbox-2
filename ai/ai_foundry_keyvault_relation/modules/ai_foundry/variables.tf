# ============================================================================
# ai_foundry モジュール 入力変数
# ============================================================================
variable "account_name" {
  description = "AI Foundry (Hub) 名"
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

# ---- AI Foundry (Hub) ------------------------------------------------------
variable "storage_account_id" {
  description = "Hub に紐付ける Storage Account の ID (必須)"
  type        = string
}

variable "key_vault_id" {
  description = <<-EOT
    Hub に紐付ける Key Vault の ID (必須)。
    本検証の主役。接続 (connection) の SAS / API キーはこの Key Vault の
    シークレットとして保存される。
  EOT
  type        = string
}

variable "application_insights_id" {
  type    = string
  default = null
}

variable "container_registry_id" {
  type    = string
  default = null
}

variable "friendly_name" {
  type    = string
  default = null
}

variable "description" {
  type    = string
  default = null
}

variable "public_network_access" {
  description = <<-EOT
    Hub 自体のパブリックアクセス ("Enabled" / "Disabled")。
    "Disabled" + amlworkspace の PE が「インバウンドのみ閉域化」の構成。
    この状態でも ARM (management.azure.com) 経由のコントロールプレーン操作は可能。
    一方 AI Foundry ポータルのデータ面は VNet 内からでないと到達できない。
  EOT
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Enabled", "Disabled"], var.public_network_access)
    error_message = "public_network_access は Enabled / Disabled のいずれかを指定してください。"
  }
}

variable "high_business_impact_enabled" {
  type    = bool
  default = false
}

# ---- AI Foundry Project ----------------------------------------------------
variable "project_name" {
  type    = string
  default = null
}

variable "project_friendly_name" {
  type    = string
  default = null
}

variable "project_description" {
  type    = string
  default = null
}

# ---- Private Endpoint ------------------------------------------------------
variable "create_private_endpoint" {
  description = "Hub の Private Endpoint (サブリソース amlworkspace) を作成するか"
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  type    = string
  default = null

  validation {
    condition     = !var.create_private_endpoint || var.private_endpoint_subnet_id != null
    error_message = "create_private_endpoint = true の場合は private_endpoint_subnet_id を指定してください。"
  }
}

variable "private_dns_zone_ids" {
  description = "amlworkspace PE 用のゾーン ID 一覧 (api.azureml.ms / notebooks.azure.net)"
  type        = list(string)
  default     = []
}
