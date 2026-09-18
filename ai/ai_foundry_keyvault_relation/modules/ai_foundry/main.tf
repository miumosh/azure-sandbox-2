# ============================================================================
# ai_foundry モジュール
# AI Foundry (Hub) + AI Foundry Project + Hub 用 Private Endpoint を構成する。
#
# ../ai_foundry/modules/ai_foundry との差分:
#   - 検証対象を絞るため AI Services (Cognitive Account) は作らない
#   - 代わりに Hub 自身の Private Endpoint (サブリソース amlworkspace) を作る
#     => 「インバウンドのみ閉域化」という前提を再現するため
#   - Private DNS Zone はルートで一元管理し、ID を受け取る
#
# 注意: managed_network ブロックは意図的に持たない。
#   本検証の前提は「アウトバウンド閉域化なし」であり、managed VNet を有効にすると
#   Hub のアウトバウンドが顧客側マネージド VNet 経由になって前提が崩れるため。
# ============================================================================
locals {
  project_name = coalesce(var.project_name, "aifp-${var.account_name}")

  # subnet_id は同一 apply 内で作成される場合 plan 時に未確定になるため、
  # count の判定にはフラグ (plan 時点で確定する値) のみを使う。
  private_endpoint_count = var.create_private_endpoint ? 1 : 0
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

  tags = var.tags
}

# ---- AI Foundry Project ----------------------------------------------------
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

# ---- Private Endpoint (インバウンド閉域化) ---------------------------------
# サブリソース amlworkspace。名前解決には
# privatelink.api.azureml.ms / privatelink.notebooks.azure.net の 2 ゾーンが要る。
resource "azurerm_private_endpoint" "hub" {
  count = local.private_endpoint_count

  name                = "pep-${var.account_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.account_name}"
    private_connection_resource_id = azurerm_ai_foundry.this.id
    subresource_names              = ["amlworkspace"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = length(var.private_dns_zone_ids) == 0 ? [] : [1]
    content {
      name                 = "pdzg-${var.account_name}"
      private_dns_zone_ids = var.private_dns_zone_ids
    }
  }

  tags = var.tags
}
