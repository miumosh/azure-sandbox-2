# ============================================================
# NSG — AKS subnet
# ============================================================
resource "azurerm_network_security_group" "aks" {
  name                = "certcsi-aks-nsg"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# CNI Overlay required rules (ref: memo/ai_order.md §3-4)
resource "azurerm_network_security_rule" "aks_allow_node_to_node" {
  name                        = "AllowNodeToNode"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "10.0.2.0/24" # aks-subnet
  destination_address_prefix  = "10.0.2.0/24" # aks-subnet
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_network_security_rule" "aks_allow_node_to_pod" {
  name                        = "AllowNodeToPod"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "10.0.2.0/24"    # aks-subnet
  destination_address_prefix  = "192.168.0.0/16" # pod CIDR (CNI Overlay)
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_network_security_rule" "aks_allow_pod_to_pod" {
  name                        = "AllowPodToPod"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "192.168.0.0/16" # pod CIDR
  destination_address_prefix  = "192.168.0.0/16" # pod CIDR
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_network_security_rule" "aks_allow_appgw_to_nodes" {
  name                        = "AllowAppGWToNodes"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "30000-32767" # NodePort range
  source_address_prefix       = "10.0.1.0/24" # appgw-subnet
  destination_address_prefix  = "10.0.2.0/24" # aks-subnet
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# ============================================================
# appgw-subnet には NSG を付けていない
#
# 公開検証 (インターネット → AppGW public frontend :80/:443) を行うが、
# NSG 未アタッチのサブネットは既定で全許可なのでそのままで到達できる。
#
# AppGW v2 のサブネットに NSG を付ける場合は、80/443 の許可だけでは足りず
#   - Inbound: GatewayManager から 65200-65535 (AppGW v2 の制御プレーン。必須)
#   - Inbound: AzureLoadBalancer
# の許可が別途必要になり、抜けると AppGW が Unhealthy になる。
# 検証の本筋 (証明書) と関係ない失敗要因を増やさないため、NSG は付けない。
#
# 旧構成にあったテスト VM 用 NSG (SSH を自分の IP に限定) は、VM 撤去に伴い削除した。
# ============================================================
