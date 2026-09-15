# ============================================================
# 取り込み先 ACR (サブスクリプション B)
# Runner VM が docker push でここへイメージをコピーする。
# B 側のワークロード (AKS / Container Apps 等) は、以後この ACR を参照する。
# ============================================================
resource "azurerm_container_registry" "target" {
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
