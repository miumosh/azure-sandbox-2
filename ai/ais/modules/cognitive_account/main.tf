# ============================================================================
# cognitive_account モジュール
# Cognitive アカウント (Speech / AIServices / OpenAI) + Private Endpoint を構成する。
# Private DNS Zone は呼び出し側で一元管理し、ここには ID だけを受け取る。
# ============================================================================
locals {
  subdomain = coalesce(var.custom_subdomain_name, var.name)

  # subnet_id は同一 apply 内で作成される場合 plan 時に未確定になるため、
  # count の判定にはフラグ (plan 時点で確定する値) のみを使う。
  private_endpoint_count = var.create_private_endpoint ? 1 : 0
}

resource "azurerm_cognitive_account" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  kind                = var.kind
  sku_name            = var.sku_name

  # PE / Entra ID 認証 / network_acls すべての必須条件。ForceNew。
  custom_subdomain_name = local.subdomain

  public_network_access_enabled = var.public_network_access_enabled
  local_auth_enabled            = var.local_auth_enabled

  # kind = AIServices では Azure が true に書き換える (ForceNew なので実態と揃える)。
  project_management_enabled = var.project_management_enabled

  identity {
    type = "SystemAssigned"
  }

  dynamic "network_acls" {
    for_each = var.network_acls == null ? [] : [var.network_acls]
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

  # Foundry v2 の virtual network injection (送信側)。
  # PE が「受信」なのに対しこれは「送信」で、Agent のコンテナが
  # 指定サブネットに注入される。作成時にしか設定できない (ForceNew 相当)。
  dynamic "network_injection" {
    for_each = var.network_injection == null ? [] : [var.network_injection]
    content {
      scenario  = network_injection.value.scenario
      subnet_id = network_injection.value.subnet_id
    }
  }

  tags = var.tags
}

# ---- Private Endpoint ------------------------------------------------------
# Cognitive アカウントの subresource は "account" の 1 種類のみ。
# ホスト名ごとの出し分けは private_dns_zone_group のゾーン数で行う。
resource "azurerm_private_endpoint" "this" {
  count = local.private_endpoint_count

  name                = "pep-${var.name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_cognitive_account.this.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  # ゾーン ID は apply 時まで未確定になり得るため、条件には「値」ではなく
  # 「キーの数」だけを使う (plan 時点で確定する)。
  dynamic "private_dns_zone_group" {
    for_each = length(var.private_dns_zone_ids) == 0 ? [] : [1]
    content {
      name                 = "pdzg-${var.name}"
      private_dns_zone_ids = values(var.private_dns_zone_ids)
    }
  }

  tags = var.tags
}
