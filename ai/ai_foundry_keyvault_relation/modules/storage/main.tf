# ============================================================================
# storage モジュール
# Storage Account + Blob コンテナ + Private Endpoint (Private Link) を構成する。
# ../ai_foundry/modules/storage をベースに、Private DNS Zone の作成を
# 呼び出し側 (ルート) へ寄せた版 (ゾーン ID を map で受け取るだけにしている)。
# ============================================================================
locals {
  # list -> map 化 (サブリソース名は Storage Account 内で一意なので key に使える)
  private_endpoints = { for pe in var.private_endpoints : pe.type => pe }
}

resource "azurerm_storage_account" "this" {
  name                             = var.storage_account_name
  resource_group_name              = var.resource_group_name
  location                         = var.location
  account_tier                     = var.account_tier
  account_replication_type         = var.account_replication_type
  account_kind                     = var.account_kind
  https_traffic_only_enabled       = true
  min_tls_version                  = var.min_tls_version
  public_network_access_enabled    = var.public_network_access_enabled
  shared_access_key_enabled        = var.shared_access_key_enabled
  allow_nested_items_to_be_public  = var.allow_nested_items_to_be_public
  cross_tenant_replication_enabled = var.cross_tenant_replication_enabled

  identity {
    type = "SystemAssigned"
  }

  dynamic "blob_properties" {
    for_each = var.blob_properties == null ? [] : [var.blob_properties]
    content {
      versioning_enabled       = blob_properties.value.versioning_enabled
      change_feed_enabled      = blob_properties.value.change_feed_enabled
      last_access_time_enabled = blob_properties.value.last_access_time_enabled

      dynamic "delete_retention_policy" {
        for_each = blob_properties.value.delete_retention_policy_days == null ? [] : [blob_properties.value.delete_retention_policy_days]
        content {
          days = delete_retention_policy.value
        }
      }
    }
  }

  dynamic "network_rules" {
    for_each = var.network_rules == null ? [] : [var.network_rules]
    content {
      default_action             = network_rules.value.default_action
      bypass                     = network_rules.value.bypass
      ip_rules                   = network_rules.value.ip_rules
      virtual_network_subnet_ids = network_rules.value.virtual_network_subnet_ids
    }
  }

  tags = var.tags

  lifecycle {
    # AI Foundry (Azure ML) は Hub に紐付けた Storage へ Studio 用の CORS ルールを
    # 自動設定するため、CORS は管理対象外にする (../ai_foundry と同じ理由)。
    ignore_changes = [blob_properties[0].cors_rule]
  }
}

# データ面 (コンテナ作成) は PE / ファイアウォールの影響を受けるため、
# public_network_access_enabled = false の場合は terraform 実行元からの到達性が必要。
resource "azurerm_storage_container" "this" {
  for_each = toset(var.container_names)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# ---- Private Endpoint (Private Link) ---------------------------------------
resource "azurerm_private_endpoint" "this" {
  for_each = local.private_endpoints

  name                = "pep-${var.storage_account_name}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = each.value.subnet_id

  private_service_connection {
    name                           = "psc-${var.storage_account_name}-${each.key}"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  # 対応するゾーンが渡されていない場合は A レコード自動登録なしで PE だけ作る。
  dynamic "private_dns_zone_group" {
    for_each = contains(keys(var.private_dns_zone_ids), each.key) ? [1] : []
    content {
      name                 = "pdzg-${var.storage_account_name}-${each.key}"
      private_dns_zone_ids = [var.private_dns_zone_ids[each.key]]
    }
  }

  tags = var.tags
}
