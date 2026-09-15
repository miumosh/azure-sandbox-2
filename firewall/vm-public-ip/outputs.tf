# ============================================================================
# 出力
# ============================================================================
output "vm_public_ip" {
  description = "VM の インスタンスレベル Public IP。インバウンドの宛先であり、宛先A/B へ出るときの送信元でもある。"
  value       = azurerm_public_ip.vm.ip_address
}

output "firewall_public_ip" {
  description = "Azure Firewall の Public IP。OS Update 等 既定経路のアウトバウンド送信元。"
  value       = azurerm_public_ip.firewall.ip_address
}

output "firewall_private_ip" {
  description = "Azure Firewall のプライベート IP (0.0.0.0/0 の next hop)"
  value       = azurerm_firewall.this.ip_configuration[0].private_ip_address
}

output "vm_ssh_private_key_path" {
  description = "生成した SSH 秘密鍵のパス"
  value       = local_sensitive_file.vm_private_key.filename
}

output "effective_routes_command" {
  description = "適用後の実効ルートを確認するコマンド"
  value       = "az network nic show-effective-route-table -g ${azurerm_resource_group.this.name} -n ${azurerm_network_interface.vm.name} -o table"
}
