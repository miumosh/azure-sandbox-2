variable "subscription_id" {
  description = "サブスクリプション A (Pull される側 / ソース ACR) の Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure Region (A・B 共通)"
  type        = string
  default     = "japaneast"
}

variable "acr_name" {
  description = "ソース ACR 名 (グローバル一意・英数字 5-50 文字)"
  type        = string
}

variable "vnet_address_space" {
  description = "A 側 VNet のアドレス空間 (B 側と重複しないこと)"
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "pe_subnet_prefix" {
  description = "A 側 Private Endpoint 用サブネットの CIDR"
  type        = list(string)
  default     = ["10.10.1.0/24"]
}
