# ============================================================
# ソース ACR (サブスクリプション A)
# ここに置かれたイメージを、B 側の Runner VM が Private Endpoint 経由で
# docker pull し、B の ACR へ docker push する。
# ============================================================
resource "azurerm_container_registry" "source" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  # Private Endpoint / パブリックアクセス無効化には Premium SKU が必須。
  sku = "Premium"

  # 認証は Managed Identity + RBAC で行うため admin user は無効。
  admin_enabled = false

  # 完全プライベート化: パブリックネットワークからのアクセスを無効。
  # アクセスは Private Endpoint 経由のみ (private_endpoint.tf)。
  public_network_access_enabled = false

  # 信頼された Azure サービス (ACR Tasks 等) からのアクセスを許可。
  network_rule_bypass_option = "AzureServices"
}
