# ============================================================================
# key_vault モジュール
# Key Vault 本体 + Private Endpoint (Private Link) を構成する。
# Private DNS Zone は呼び出し側 (ルート) で一元管理し、ID を受け取る。
# ============================================================================
resource "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = var.sku_name

  rbac_authorization_enabled = var.rbac_authorization_enabled
  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  public_network_access_enabled = var.public_network_access_enabled

  dynamic "network_acls" {
    for_each = var.network_acls == null ? [] : [var.network_acls]
    content {
      default_action             = network_acls.value.default_action
      bypass                     = network_acls.value.bypass
      ip_rules                   = network_acls.value.ip_rules
      virtual_network_subnet_ids = network_acls.value.virtual_network_subnet_ids
    }
  }

  tags = var.tags
}

# ---- Private Endpoint (Private Link) ---------------------------------------
resource "azurerm_private_endpoint" "this" {
  count = var.create_private_endpoint ? 1 : 0

  name                = "pep-${var.key_vault_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "psc-${var.key_vault_name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  dynamic "private_dns_zone_group" {
    for_each = length(var.private_dns_zone_ids) == 0 ? [] : [1]
    content {
      name                 = "pdzg-${var.key_vault_name}"
      private_dns_zone_ids = var.private_dns_zone_ids
    }
  }

  tags = var.tags
}
