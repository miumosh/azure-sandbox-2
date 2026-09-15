# ============================================================
# RBAC — import 実行 ID へソース ACR の読み取り/import 権限を付与
# ------------------------------------------------------------
# 公式手順では、import 実行 ID は source/target 双方に
# "Container Registry Data Importer and Data Reader" ロールが必要。
# (旧構成では source 側は AcrPull でも可)
# ============================================================
resource "azurerm_role_assignment" "runner_importer_source" {
  scope                = azurerm_container_registry.source.id
  role_definition_name = "Container Registry Data Importer and Data Reader"
  principal_id         = var.import_runner_principal_id
}
