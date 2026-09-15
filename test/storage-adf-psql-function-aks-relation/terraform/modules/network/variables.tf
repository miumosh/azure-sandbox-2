# ============================================================================
# network モジュール 入力変数
# VNet / サブネット / Private DNS Zone + リンク / ピアリング / NSG を
# object 型のマップで受け取り、Hub・Spoke 両 env から再利用する。
# ============================================================================
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

variable "vnet_name" {
  type = string
}

variable "address_space" {
  type = list(string)
}

# サブネット (キー = 論理名。env から subnet_ids[キー] で参照する)
variable "subnets" {
  type = map(object({
    name                              = string
    address_prefixes                  = list(string)
    private_endpoint_network_policies = optional(string, "Disabled")
    service_endpoints                 = optional(list(string), [])
    delegation = optional(object({
      name         = string
      service_name = string
      actions      = list(string)
    }))
  }))
  default = {}
}

# Private DNS Zone (キー = 論理名。各 zone は複数の VNet リンクを持てる)
variable "dns_zones" {
  type = map(object({
    name = string
    links = optional(map(object({
      name                 = string
      virtual_network_id   = string
      registration_enabled = optional(bool, false)
    })), {})
  }))
  default = {}
}

# VNet ピアリング (remote_virtual_network_id が空のものは env 側で map から除外する)
variable "peerings" {
  type = map(object({
    name                         = string
    remote_virtual_network_id    = string
    allow_virtual_network_access = optional(bool, true)
    allow_forwarded_traffic      = optional(bool, true)
  }))
  default = {}
}

# NSG (キー = 論理名。subnet_key で関連付けるサブネットを指定)
variable "network_security_groups" {
  type = map(object({
    name       = string
    subnet_key = string
    rules = list(object({
      name                       = string
      priority                   = number
      direction                  = string
      access                     = string
      protocol                   = string
      source_port_range          = string
      destination_port_range     = string
      source_address_prefix      = string
      destination_address_prefix = string
    }))
  }))
  default = {}
}
