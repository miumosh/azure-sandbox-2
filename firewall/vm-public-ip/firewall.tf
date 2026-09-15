# ============================================================================
# Azure Firewall (既定のアウトバウンド経路)
#
# 0.0.0.0/0 の UDR で吸い上げた通信をここで検査する。
# Firewall は パブリック宛の通信を自分の Public IP に SNAT するため、
# OS Update 等の送信元 IP は「Firewall の Public IP」になる。
# 一方で 宛先A/B とインバウンドの戻りは UDR で迂回させるので、
# こちらの送信元 IP は「VM の Public IP」になる。この差が本構成の要。
# ============================================================================
resource "azurerm_public_ip" "firewall" {
  name                = "pip-afw-${local.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# Basic SKU は管理トラフィック専用の Public IP / サブネットが必須
resource "azurerm_public_ip" "firewall_mgmt" {
  count = local.firewall_needs_mgmt_subnet ? 1 : 0

  name                = "pip-afw-mgmt-${local.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_firewall_policy" "this" {
  name                = "afwp-${local.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = var.firewall_sku_tier
  tags                = local.tags
}

resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  name               = "rcg-egress"
  firewall_policy_id = azurerm_firewall_policy.this.id
  priority           = 100

  # ---- L3/L4: 名前解決と時刻同期 -----------------------------------------
  network_rule_collection {
    name     = "nrc-infra"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "AllowDns"
      protocols             = ["UDP", "TCP"]
      source_addresses      = [local.subnets.vm.prefix]
      destination_addresses = ["*"]
      destination_ports     = ["53"]
    }

    rule {
      name                  = "AllowNtp"
      protocols             = ["UDP"]
      source_addresses      = [local.subnets.vm.prefix]
      destination_addresses = ["*"]
      destination_ports     = ["123"]
    }
  }

  # ---- L7: OS Update / ツール取得 ----------------------------------------
  # 宛先A/B はここに書かない。ルートで Firewall を通らないため、
  # ここに書いても評価されず「効いているつもりの穴」になる。
  application_rule_collection {
    name     = "arc-os-update"
    priority = 200
    action   = "Allow"

    rule {
      name              = "AllowOsUpdateAndTooling"
      source_addresses  = [local.subnets.vm.prefix]
      destination_fqdns = local.fw_allowed_fqdns

      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
    }
  }
}

resource "azurerm_firewall" "this" {
  name                = "afw-${local.prefix}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku_name            = "AZFW_VNet"
  sku_tier            = var.firewall_sku_tier
  firewall_policy_id  = azurerm_firewall_policy.this.id
  tags                = local.tags

  ip_configuration {
    name                 = "ipconfig1"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  dynamic "management_ip_configuration" {
    for_each = local.firewall_needs_mgmt_subnet ? [1] : []
    content {
      name                 = "mgmtipconfig"
      subnet_id            = azurerm_subnet.firewall_mgmt[0].id
      public_ip_address_id = azurerm_public_ip.firewall_mgmt[0].id
    }
  }
}
