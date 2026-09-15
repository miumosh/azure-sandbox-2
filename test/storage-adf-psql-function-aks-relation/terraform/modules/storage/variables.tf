# ============================================================================
# storage モジュール 入力変数 (アップロード / アーカイブ用 Storage Account)
# ============================================================================
variable "name" {
  type = string
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

variable "allowed_upload_ip" {
  description = "Storage Explorer からのアクセスを許可するグローバル IP (裸 IP / CIDR)"
  type        = string
}

variable "upload_container_name" {
  type = string
}

variable "archive_container_name" {
  type = string
}

variable "versioning_enabled" {
  type    = bool
  default = true
}

variable "delete_retention_days" {
  type    = number
  default = 7
}

variable "sas_expiry" {
  description = "アップロード用サービス SAS の有効期間 (timeadd 形式)"
  type        = string
  default     = "720h"
}
