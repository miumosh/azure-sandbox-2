output "jumpbox_name" {
  description = "踏み台 VM 名 (public IP へ SSH して psql / zip アップロードを行う)"
  value       = azurerm_linux_virtual_machine.jumpbox.name
}

output "jumpbox_principal_id" {
  description = "踏み台 VM の System-assigned MI の object_id (PostgreSQL の AAD ロール作成に使用)"
  value       = azurerm_linux_virtual_machine.jumpbox.identity[0].principal_id
}

output "jumpbox_public_ip" {
  description = "踏み台 VM の public IP (ローカルから SSH/scp する接続先)"
  value       = azurerm_public_ip.jumpbox.ip_address
}
