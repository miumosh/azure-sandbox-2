# ============================================================
# import 実行用 User Assigned Managed Identity
# ------------------------------------------------------------
# この Identity で `az login --identity` し、`az acr import` を実行する。
#   - ソース ACR (A): Data Importer and Data Reader … from 側で付与
#   - import 先 ACR (B): Data Importer and Data Reader … role.tf で付与
# 注: import は ARM(コントロールプレーン)操作のため、VM/VNet は不要。
#     CI(OIDC フェデレーション) や Cloud Shell でこの UAMI/任意の権限保有 ID から実行可能。
# ============================================================
resource "azurerm_user_assigned_identity" "runner" {
  name                = var.runner_identity_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}
