# ============================================================
# ソース ACR (サブスクリプション A) — Premium / 完全プライベート
# ------------------------------------------------------------
# public 無効でも、network_rule_bypass_option = "AzureServices"
# (= allow trusted services) により、ACR import (信頼サービス) が
# 同一 Entra テナント内でこの ACR を読み取れる。Private Endpoint は不要。
# ============================================================
resource "azurerm_container_registry" "source" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku           = "Premium"
  admin_enabled = false

  public_network_access_enabled = false

  # import を含む信頼 Azure サービスのアクセスを許可 (import 動作の必須条件)。
  network_rule_bypass_option = "AzureServices"
}
