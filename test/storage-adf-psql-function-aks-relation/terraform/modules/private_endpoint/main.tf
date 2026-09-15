# ============================================================================
# private_endpoint モジュール
# サブリソース指定の Private Endpoint を 1 つ作成する (任意で DNS Zone Group 付き)。
# ============================================================================
resource "azurerm_private_endpoint" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = var.private_service_connection_name
    private_connection_resource_id = var.private_connection_resource_id
    is_manual_connection           = false
    subresource_names              = var.subresource_names
  }

  dynamic "private_dns_zone_group" {
    for_each = length(var.private_dns_zone_ids) > 0 ? [1] : []
    content {
      name                 = var.dns_zone_group_name
      private_dns_zone_ids = var.private_dns_zone_ids
    }
  }
}
