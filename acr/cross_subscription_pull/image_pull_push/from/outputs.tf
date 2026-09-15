# to (B) 側の変数 source_* にそのまま渡すための出力群。

output "source_acr_name" {
  description = "ソース ACR 名"
  value       = azurerm_container_registry.source.name
}

output "source_acr_login_server" {
  description = "ソース ACR のログインサーバー (例: xxx.azurecr.io)"
  value       = azurerm_container_registry.source.login_server
}

output "source_acr_id" {
  description = "ソース ACR の Resource ID (to の AcrPull ロール付与に使用)"
  value       = azurerm_container_registry.source.id
}

output "source_rg_name" {
  description = "A 側リソースグループ名 (共有 DNS ゾーンへの VNet リンク作成に使用)"
  value       = azurerm_resource_group.rg.name
}

output "source_vnet_id" {
  description = "A 側 VNet の Resource ID (VNet ピアリングに使用)"
  value       = azurerm_virtual_network.vnet.id
}

output "source_vnet_name" {
  description = "A 側 VNet 名 (VNet ピアリングに使用)"
  value       = azurerm_virtual_network.vnet.name
}

output "source_dns_zone_id" {
  description = "共有 Private DNS ゾーンの Resource ID (B の PE / VNet リンクで参照)"
  value       = azurerm_private_dns_zone.acr.id
}
