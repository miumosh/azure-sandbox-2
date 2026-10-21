# ============================================================
# RBAC — オペレータ (Entra ユーザ) に両 ACR の Data Importer を付与
# ------------------------------------------------------------
# 公式手順: source / target の双方に
# "Container Registry Data Importer and Data Reader" を ACR スコープで付与。
# ============================================================
resource "azurerm_role_assignment" "src_importer" {
  count                = var.assign_src_importer ? 1 : 0
  provider             = azurerm.src
  scope                = azurerm_container_registry.src.id
  role_definition_name = "Container Registry Data Importer and Data Reader"
  principal_id         = var.operator_object_id
  principal_type       = "User"
}

resource "azurerm_role_assignment" "dst_importer" {
  count                = var.assign_dst_importer ? 1 : 0
  provider             = azurerm.dst
  scope                = azurerm_container_registry.dst.id
  role_definition_name = "Container Registry Data Importer and Data Reader"
  principal_id         = var.operator_object_id
  principal_type       = "User"
}
