# ============================================================================
# ai_foundry モジュール
# AI Foundry (Hub) + AI Foundry Project + AI Services (Cognitive Account) +
# AI Services 用の Private Endpoint (Private Link) / Private DNS Zone を構成する。
# - Hub が必須とする Storage Account / Key Vault は呼び出し側から ID で受け取る。
# - AI Foundry への model deployment 追加は AzureRM 未対応のため手動作成が必要。
# ============================================================================
locals {
  ai_services_name      = coalesce(var.ai_services_name, "ais-${var.account_name}")
  ai_services_subdomain = coalesce(var.ai_services_custom_subdomain_name, local.ai_services_name)
  project_name          = coalesce(var.project_name, "aifp-${var.account_name}")

  # subnet_id は同一 apply 内で作成される場合 plan 時に未確定になるため、
  # count の判定にはフラグ (plan 時点で確定する値) のみを使う。
  private_endpoint_count = var.create_private_endpoint ? 1 : 0

  # 本モジュールで作成するゾーン (ゾーン名をそのまま key にする)
  managed_dns_zone_names = var.create_private_dns_zone ? {
    for name in var.private_dns_zone_names : name => name
  } : {}

  # ゾーン × リンク先 VNet を 1 段の map に平坦化する
  dns_zone_links = merge([
    for zone_key, zone_name in local.managed_dns_zone_names : {
      for link_key, vnet_id in var.private_dns_zone_virtual_network_ids :
      "${zone_key}.${link_key}" => {
        zone_key           = zone_key
        link_key           = link_key
        virtual_network_id = vnet_id
      }
    }
  ]...)

  # PE の DNS Zone Group が参照するゾーン ID (自前作成 or 呼び出し側から受領)
  private_dns_zone_ids = var.create_private_dns_zone ? {
    for name, zone in azurerm_private_dns_zone.ai_services : name => zone.id
  } : var.private_dns_zone_ids
}

# ---- AI Services (Cognitive Account) ---------------------------------------
# kind = "AIServices" は OpenAI / Speech / Vision 等をまとめた統合エンドポイント。
resource "azurerm_cognitive_account" "ai_services" {
  name                  = local.ai_services_name
  custom_subdomain_name = local.ai_services_subdomain
  location              = var.location
  resource_group_name   = var.resource_group_name
  kind                  = "AIServices"
  sku_name              = var.ai_services_sku_name

  public_network_access_enabled = var.ai_services_public_network_access_enabled
  local_auth_enabled            = var.ai_services_local_auth_enabled

  # AI Foundry 連携時に Azure 側が true にする属性。ForceNew のため実態と揃えておく。
  project_management_enabled = var.ai_services_project_management_enabled

  identity {
    type = "SystemAssigned"
  }

  dynamic "network_acls" {
    for_each = var.ai_services_network_acls == null ? [] : [var.ai_services_network_acls]
    content {
      default_action = network_acls.value.default_action
      bypass         = network_acls.value.bypass
      ip_rules       = network_acls.value.ip_rules

      dynamic "virtual_network_rules" {
        for_each = network_acls.value.virtual_network_subnet_ids
        content {
          subnet_id = virtual_network_rules.value
        }
      }
    }
  }

  tags = var.tags
}

# ---- AI Foundry (Hub) ------------------------------------------------------
resource "azurerm_ai_foundry" "this" {
  name                = var.account_name
  location            = var.location
  resource_group_name = var.resource_group_name

  storage_account_id      = var.storage_account_id
  key_vault_id            = var.key_vault_id
  application_insights_id = var.application_insights_id
  container_registry_id   = var.container_registry_id

  friendly_name                = var.friendly_name
  description                  = var.description
  public_network_access        = var.public_network_access
  high_business_impact_enabled = var.high_business_impact_enabled

  identity {
    type = "SystemAssigned"
  }

  dynamic "managed_network" {
    for_each = var.managed_network_isolation_mode == null ? [] : [var.managed_network_isolation_mode]
    content {
      isolation_mode = managed_network.value
    }
  }

  tags = var.tags
}

# ---- AI Foundry Project ----------------------------------------------------
# location / resource group は Hub から継承される。
resource "azurerm_ai_foundry_project" "this" {
  name               = local.project_name
  location           = azurerm_ai_foundry.this.location
  ai_services_hub_id = azurerm_ai_foundry.this.id

  friendly_name = var.project_friendly_name
  description   = var.project_description

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# ---- Private DNS Zone (Private Link 用の名前解決) ---------------------------
resource "azurerm_private_dns_zone" "ai_services" {
  for_each = local.managed_dns_zone_names

  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "ai_services" {
  for_each = local.dns_zone_links

  # ゾーン名の "." はリンク名に使えないため "-" に置換する
  name                  = "pdzvnl-${replace(each.value.zone_key, ".", "-")}-${each.value.link_key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.ai_services[each.value.zone_key].name
  virtual_network_id    = each.value.virtual_network_id
  registration_enabled  = false
  tags                  = var.tags
}

# ---- Private Endpoint (Private Link) ---------------------------------------
resource "azurerm_private_endpoint" "ai_services" {
  count = local.private_endpoint_count

  name                = "pep-${local.ai_services_name}"
  location            = coalesce(var.private_endpoint_location, var.location)
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${local.ai_services_name}"
    private_connection_resource_id = azurerm_cognitive_account.ai_services.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = length(local.private_dns_zone_ids) == 0 ? [] : [1]
    content {
      name                 = "pdzg-${local.ai_services_name}"
      private_dns_zone_ids = values(local.private_dns_zone_ids)
    }
  }

  tags = var.tags
}
