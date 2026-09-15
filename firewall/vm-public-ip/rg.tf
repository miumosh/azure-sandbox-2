# ============================================================================
# リソースグループ
# ============================================================================
resource "azurerm_resource_group" "this" {
  name     = "rg-${local.prefix}-${local.suffix}"
  location = local.location
  tags     = local.tags
}
