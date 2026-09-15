# ============================================================
# import 先 ACR (サブスクリプション B) — Premium / 完全プライベート
# ------------------------------------------------------------
# import は ARM コントロールプレーン操作で、ここへ書き込むのは ACR 自身。
# public 無効でも import は成立する (allow trusted services を有効化)。
# ============================================================
resource "azurerm_container_registry" "target" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku           = "Premium"
  admin_enabled = false

  public_network_access_enabled = false

  # import を含む信頼 Azure サービスのアクセスを許可。
  network_rule_bypass_option = "AzureServices"
}
