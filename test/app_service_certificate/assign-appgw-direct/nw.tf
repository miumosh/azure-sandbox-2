# ============================================================
# VNet
# ============================================================
resource "azurerm_virtual_network" "vnet" {
  name                = "certdirect-vnet"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  address_space       = ["10.0.0.0/16"]
}

# ============================================================
# Subnets
# ============================================================
resource "azurerm_subnet" "appgw" {
  name                 = "appgw-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

  # Required delegation for Application Gateway v2
  #
  # actions は Azure 側が "Microsoft.Network/virtualNetworks/subnets/join/action" に
  # 正規化して返すため、config でも同じ値を書く。
  # ".../subnets/action" と書くと apply しても Azure が join/action で返し続け、
  # plan が毎回 "1 to change" になる (恒久 diff)。
  delegation {
    name = "appgw-delegation"
    service_delegation {
      name    = "Microsoft.Network/applicationGateways"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# 公開検証に切り替えたためテスト VM は撤去した (vm-subnet 10.0.3.0/24 も不要)。
# 検証はローカル PC から公開 FQDN に対して直接行う (README 参照)。
