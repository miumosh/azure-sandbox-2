# ============================================================================
# jumpbox モジュール 入力変数 (psql / Function zip ビルド・アップロード用踏み台 VM)
# ============================================================================
variable "jumpbox_name" {
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

variable "jumpbox_subnet_id" {
  type = string
}

variable "jumpbox_vm_size" {
  type    = string
  default = "Standard_B1s"
}

variable "jumpbox_admin_username" {
  type    = string
  default = "azureuser"
}

variable "jumpbox_admin_password" {
  type      = string
  sensitive = true
}
