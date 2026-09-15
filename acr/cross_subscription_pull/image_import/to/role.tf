# ============================================================
# RBAC — import 実行 ID へ import 先 ACR の import/read 権限を付与
# (ソース ACR 側の同ロールは from で付与)
# ============================================================
resource "azurerm_role_assignment" "runner_importer_target" {
  scope                = azurerm_container_registry.target.id
  role_definition_name = "Container Registry Data Importer and Data Reader"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
}
