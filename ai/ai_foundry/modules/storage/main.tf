# ============================================================================
# storage モジュール
# Storage Account + Blob コンテナ + Private Endpoint (Private Link) +
# Private DNS Zone (+ VNet リンク) を一式で構成する。
# - PE のサブリソース (blob / web / file ...) ごとに対応する Private DNS Zone を
#   自動で引き当てるため、呼び出し側はゾーン名を意識しなくてよい。
# ============================================================================
locals {
  # サブリソース名 -> Private DNS Zone 名 の対応表 (Azure 固定値)
  subresource_dns_zone_names = {
    blob  = "privatelink.blob.core.windows.net"
    file  = "privatelink.file.core.windows.net"
    queue = "privatelink.queue.core.windows.net"
    table = "privatelink.table.core.windows.net"
    web   = "privatelink.web.core.windows.net"
    dfs   = "privatelink.dfs.core.windows.net"
  }

  # list -> map 化 (サブリソース名は Storage Account 内で一意なので key に使える)
  private_endpoints = { for pe in var.private_endpoints : pe.type => pe }

  # 本モジュールで作成するゾーン (サブリソース名 => ゾーン名)
  managed_dns_zone_names = var.create_private_dns_zone ? {
    for type, _ in local.private_endpoints : type => local.subresource_dns_zone_names[type]
  } : {}

  # ゾーン × リンク先 VNet を 1 段の map に平坦化する
  dns_zone_links = merge([
    for type, zone_name in local.managed_dns_zone_names : {
      for link_key, vnet_id in var.private_dns_zone_virtual_network_ids :
      "${type}.${link_key}" => {
        type               = type
        link_key           = link_key
        virtual_network_id = vnet_id
      }
    }
  ]...)

  # PE の DNS Zone Group が参照するゾーン ID (自前作成 or 呼び出し側から受領)
  private_dns_zone_ids = var.create_private_dns_zone ? {
    for type, zone in azurerm_private_dns_zone.this : type => zone.id
  } : var.private_dns_zone_ids
}

# ---- Storage Account -------------------------------------------------------
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
    # 自動設定する (https://ml.azure.com / https://ai.azure.com 等のオリジン)。
    # Terraform 側で管理すると毎回それを削除しようとして差分が出続け、
    # 適用すると Studio のファイルブラウザが壊れるため、CORS は管理対象外にする。
    ignore_changes = [blob_properties[0].cors_rule]
  }
}

resource "azurerm_storage_account_static_website" "this" {
  count = var.enable_static_website ? 1 : 0

  storage_account_id = azurerm_storage_account.this.id
  index_document     = var.static_website_index_document
  error_404_document = var.static_website_error_404_document
}

# データ面 (コンテナ作成) は PE / ファイアウォールの影響を受けるため、
# public_network_access_enabled = false の場合は terraform 実行元からの到達性が必要。
resource "azurerm_storage_container" "this" {
  for_each = toset(var.container_names)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# ---- Private DNS Zone (Private Link 用の名前解決) ---------------------------
resource "azurerm_private_dns_zone" "this" {
  for_each = local.managed_dns_zone_names

  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.dns_zone_links

  name                  = "pdzvnl-${var.storage_account_name}-${each.value.type}-${each.value.link_key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.type].name
  virtual_network_id    = each.value.virtual_network_id
  registration_enabled  = false
  tags                  = var.tags
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

  # 対応するゾーンが無い場合は A レコード自動登録なしで PE だけ作る。
  # ゾーン ID は apply 時まで未確定になり得るため、条件には key の有無のみを使う。
  dynamic "private_dns_zone_group" {
    for_each = contains(keys(local.private_dns_zone_ids), each.key) ? [1] : []
    content {
      name                 = "pdzg-${var.storage_account_name}-${each.key}"
      private_dns_zone_ids = [local.private_dns_zone_ids[each.key]]
    }
  }

  tags = var.tags
}
