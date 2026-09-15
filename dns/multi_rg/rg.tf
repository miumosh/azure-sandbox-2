# ============================================================================
# リソースグループ (3 つ)
# ============================================================================
resource "azurerm_resource_group" "this" {
  for_each = local.resource_groups

  name     = each.value.name
  location = local.location
  tags     = merge(local.tags, { purpose = each.value.purpose })
}
