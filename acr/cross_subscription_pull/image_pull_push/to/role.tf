# ============================================================
# RBAC — クロスサブスクリプション Pull (docker pull/push 方式)
# ------------------------------------------------------------
# Runner VM の UAMI に以下を付与:
#   - ソース ACR (A) へ AcrPull  … docker pull (alias provider "src" で A 側に作成)
#   - 取り込み先 ACR (B) へ AcrPush … docker push
# AcrPush は pull/push 両方を含む。
# ============================================================

# A 側: ソース ACR への AcrPull
resource "azurerm_role_assignment" "runner_acrpull_source" {
  provider             = azurerm.src
  scope                = var.source_acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
}

# B 側: 取り込み先 ACR への AcrPush
resource "azurerm_role_assignment" "runner_acrpush_target" {
  scope                = azurerm_container_registry.target.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
}
