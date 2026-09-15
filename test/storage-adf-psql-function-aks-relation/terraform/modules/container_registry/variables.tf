# ============================================================================
# container_registry モジュール 入力変数 (Premium ACR + AcrPull)
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

variable "public_network_access_enabled" {
  description = "push 時のみ true。既定 false = 閉域 (PE のみ)"
  type        = bool
  default     = false
}

variable "aks_kubelet_object_id" {
  description = "AcrPull を付与する AKS kubelet MI の object_id (cross-sub)。空なら付与しない"
  type        = string
  default     = ""
}
