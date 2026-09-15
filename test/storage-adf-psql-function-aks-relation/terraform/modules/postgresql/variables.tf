# ============================================================================
# postgresql モジュール 入力変数 (Flexible Server)
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

variable "sku_name" {
  type    = string
  default = "B_Standard_B2s"
}

variable "postgresql_version" {
  type    = string
  default = "16"
}

variable "storage_mb" {
  type    = number
  default = 32768
}

variable "administrator_login" {
  type    = string
  default = "psqladmin"
}

variable "administrator_password" {
  type      = string
  sensitive = true
}

variable "database_name" {
  type    = string
  default = "appdb"
}

variable "charset" {
  type    = string
  default = "UTF8"
}

variable "collation" {
  type    = string
  default = "en_US.utf8"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

# Entra ID 管理者 (object_id は env 側で coalesce 済みの実値を渡す)
variable "entra_admin_tenant_id" {
  type = string
}

variable "entra_admin_object_id" {
  type = string
}

variable "entra_admin_principal_name" {
  type = string
}

variable "entra_admin_principal_type" {
  type    = string
  default = "User"
}
