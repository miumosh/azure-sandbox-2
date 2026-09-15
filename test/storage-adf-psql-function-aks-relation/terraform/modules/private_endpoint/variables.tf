# ============================================================================
# private_endpoint モジュール 入力変数 (汎用 Private Endpoint)
# ============================================================================
variable "name" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "private_connection_resource_id" {
  type = string
}

variable "subresource_names" {
  type = list(string)
}

variable "private_service_connection_name" {
  type = string
}

# Private DNS Zone を紐付けない場合は空リスト
variable "private_dns_zone_ids" {
  type    = list(string)
  default = []
}

variable "dns_zone_group_name" {
  type    = string
  default = "default"
}

variable "tags" {
  type    = map(string)
  default = {}
}
