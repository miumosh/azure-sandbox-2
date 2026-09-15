# ============================================================================
# aks モジュール 入力変数
# ============================================================================
variable "name" {
  type = string
}

variable "dns_prefix" {
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

variable "node_size" {
  type    = string
  default = "Standard_D2s_v3"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "subnet_id" {
  type = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "service_cidr" {
  type    = string
  default = "10.200.0.0/16"
}

variable "dns_service_ip" {
  type    = string
  default = "10.200.0.10"
}

variable "os_disk_size_gb" {
  type    = number
  default = 30
}
