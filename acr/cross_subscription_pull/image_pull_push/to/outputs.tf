output "runner_identity_client_id" {
  description = "Runner UAMI の client_id (az login --identity --username で使用)"
  value       = azurerm_user_assigned_identity.runner.client_id
}

output "runner_vm_public_ip" {
  description = "Runner VM の SSH 接続先 (Public IP)"
  value       = azurerm_public_ip.vm.ip_address
}

output "runner_vm_ssh_cmd" {
  description = "Runner VM への SSH コマンド"
  value       = "ssh ${var.vm_admin_username}@${azurerm_public_ip.vm.ip_address}"
}

output "target_acr_login_server" {
  description = "取り込み先 ACR のログインサーバー"
  value       = azurerm_container_registry.target.login_server
}

# Runner VM 上で実行する pull/push 手順 (Private Endpoint 経由)
output "pull_push_steps" {
  description = "Runner VM 上での docker pull(A) / push(B) 実行手順"
  value = join("\n", [
    "# 1) UAMI でログイン",
    "az login --identity --username ${azurerm_user_assigned_identity.runner.client_id}",
    "# 2) 両 ACR へログイン (login server は Private DNS で私設 IP に解決される)",
    "az acr login --name ${var.source_acr_login_server}",
    "az acr login --name ${azurerm_container_registry.target.login_server}",
    "# 3) ソース A から pull → 取り込み先 B へ tag & push",
    "docker pull ${var.source_acr_login_server}/${var.sample_image}",
    "docker tag ${var.source_acr_login_server}/${var.sample_image} ${azurerm_container_registry.target.login_server}/${var.sample_image}",
    "docker push ${azurerm_container_registry.target.login_server}/${var.sample_image}",
  ])
}
