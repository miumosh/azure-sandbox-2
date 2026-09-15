# ============================================================
# Runner VM 用 User Assigned Managed Identity
# ------------------------------------------------------------
# Runner VM がこの Identity で `az login --identity` し、
#   - ソース ACR (A): AcrPull  → docker pull
#   - 取り込み先 ACR (B): AcrPush → docker push
# を行う。RBAC は role.tf で付与。
# ============================================================
resource "azurerm_user_assigned_identity" "runner" {
  name                = var.runner_identity_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}
