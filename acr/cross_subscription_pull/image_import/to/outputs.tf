output "runner_identity_principal_id" {
  description = "import 実行 UAMI の principal_id (from の変数 import_runner_principal_id に渡す)"
  value       = azurerm_user_assigned_identity.runner.principal_id
}

output "runner_identity_client_id" {
  description = "import 実行 UAMI の client_id (az login --identity --username で使用)"
  value       = azurerm_user_assigned_identity.runner.client_id
}

output "target_acr_name" {
  description = "import 先 ACR 名"
  value       = azurerm_container_registry.target.name
}

# UAMI で実行する場合のログインコマンド (CI/VM/Cloud Shell など任意ホスト)
output "az_login_identity_cmd" {
  description = "UAMI でのログインコマンド"
  value       = "az login --identity --username ${azurerm_user_assigned_identity.runner.client_id}"
}

# クロスサブスクリプション import コマンド。
# ソース A は public 無効のため、--source は repo:tag のみ・ソースは --registry に resource ID で指定。
output "az_acr_import_cmd" {
  description = "ソース ACR (A) から import 先 ACR (B) へイメージを import するコマンド"
  value = join(" ", [
    "az acr import",
    "--name ${azurerm_container_registry.target.name}",
    "--source ${var.sample_image}",
    "--image ${var.sample_image}",
    "--registry ${var.source_acr_id}",
  ])
}
