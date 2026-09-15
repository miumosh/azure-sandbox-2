
# ============================================================================
# Outputs (spoke-subscription / 利用者へ共有する値)
# ============================================================================
output "hub_vnet_id" {
  description = "Hub VNet のリソース ID (Spoke 側のピアリング / DNS リンクに使用)"
  value       = module.network.vnet_id
}

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "subscription_id" {
  description = "Hub サブスクリプション ID (CLI コマンドの --subscription 用)"
  value       = var.subscription_id
}

output "storage_account_name" {
  value = module.storage.name
}

output "upload_container_name" {
  description = "CSV アップロード先コンテナ名 (アップロードスクリプト用)"
  value       = module.storage.upload_container_name
}

output "upload_container_sas_url" {
  description = "Storage Explorer に貼り付けて upload コンテナへ接続するための SAS URL"
  value       = module.storage.upload_container_sas_url
  sensitive   = true
}

output "acr_name" {
  value = module.container_registry.name
}

output "acr_login_server" {
  description = "AKS Deployment のイメージ参照に使う (例: ci00acr.azurecr.io)"
  value       = module.container_registry.login_server
}

output "jumpbox_name" {
  description = "踏み台 VM 名 (public IP へ SSH して psql / zip アップロードを行う)"
  value       = module.jumpbox.jumpbox_name
}

output "jumpbox_public_ip" {
  description = "踏み台 VM の public IP (ローカルから SSH/scp する接続先)"
  value       = module.jumpbox.jumpbox_public_ip
}

output "jumpbox_principal_id" {
  description = "踏み台 VM の System-assigned MI の object_id (PostgreSQL の AAD ロール作成に使用)"
  value       = module.jumpbox.jumpbox_principal_id
}

output "data_factory_name" {
  value = try(module.data_factory["main"].name, null)
}

output "data_factory_principal_id" {
  description = "ADF の SystemAssigned マネージドID (PostgreSQL のロール付与に使用)。ADF 未作成時は null"
  value       = try(module.data_factory["main"].principal_id, null)
}
