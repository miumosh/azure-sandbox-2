# ============================================================================
# 出力値 (verify.sh がここを読んで検証コマンドを組み立てる)
# ============================================================================
output "resource_group_names" {
  description = "作成した 3 つのリソースグループ名"
  value       = { for k, v in azurerm_resource_group.this : k => v.name }
}

output "private_dns_zone_name" {
  description = "RG1 / RG2 の双方に作成した (同名の) Private DNS ゾーン名"
  value       = local.private_dns_zone_name
}

output "private_dns_zone_ids" {
  description = "同名ゾーンのリソース ID。RG 部分だけが異なることを確認する"
  value       = { for k, v in azurerm_private_dns_zone.this : k => v.id }
}

output "storage_blob_fqdns" {
  description = "各 Storage の Blob FQDN (VM から名前解決を試す対象)"
  value       = { for k, v in local.storage_accounts : k => "${v.name}.blob.core.windows.net" }
}

output "private_endpoint_ips" {
  description = "各 Private Endpoint の実際のプライベート IP (期待値の答え合わせ用)"
  value       = { for k, v in azurerm_private_endpoint.this : k => v.private_service_connection[0].private_ip_address }
}

output "conflict_fqdn" {
  description = "両ゾーンに同名で置いた A レコードの FQDN"
  value       = local.conflict_fqdn
}

output "conflict_expected_ips" {
  description = "conflict_fqdn の期待解決先。どちらのゾーンがリンクされているかで決まる"
  value       = local.conflict_records
}

output "vm_vnet_dns_link" {
  description = "現在 VNet3 にリンクしているゾーンの所属 RG"
  value       = var.vm_vnet_dns_link
}

output "vm_name" {
  description = "検証 VM 名"
  value       = azurerm_linux_virtual_machine.vm.name
}

output "vm_public_ip" {
  description = "検証 VM の Public IP (SSH する場合に使用)"
  value       = azurerm_public_ip.vm.ip_address
}

output "vm_ssh_command" {
  description = "SSH コマンド (var.allowed_client_ips を設定した場合のみ到達可能)"
  value       = "ssh -i ./generated/${local.vm.name}_id_rsa ${local.vm.admin_username}@${azurerm_public_ip.vm.ip_address}"
}
