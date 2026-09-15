# ============================================================================
# container_registry モジュール
# Premium ACR (PE 必須) + AKS kubelet への AcrPull (cross-subscription)。
# - Private DNS Zone / Private Endpoint は呼び出し側 (network / env) が持つ。
# ============================================================================
resource "azurerm_container_registry" "this" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = var.public_network_access_enabled

  tags = var.tags
}

# AKS の kubelet MI に AcrPull を付与 (spoke output → var で受け取る)
resource "azurerm_role_assignment" "aks_acrpull" {
  count                = var.aks_kubelet_object_id == "" ? 0 : 1
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = var.aks_kubelet_object_id
}
