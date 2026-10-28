# ============================================================================
# 出力値
# - キー / 接続文字列などの機微情報は出力しない
# ============================================================================
output "resource_group_name" {
  description = "検証用リソースグループ名"
  value       = azurerm_resource_group.this.name
}

output "subscription_plans" {
  description = "サブスクリプション単位で Standard にした Defender プラン"
  value       = sort(keys(azurerm_security_center_subscription_pricing.this))
}

output "storage_account_name" {
  description = "Defender for Storage の検証対象ストレージアカウント名"
  value       = try(azurerm_storage_account.this[0].name, null)
}

output "aks_name" {
  description = "Defender for Containers の検証対象 AKS 名"
  value       = try(azurerm_kubernetes_cluster.this[0].name, null)
}

output "acr_login_server" {
  description = "Defender for Containers (脆弱性評価) の検証対象 ACR"
  value       = try(azurerm_container_registry.this[0].login_server, null)
}

output "postgresql_fqdn" {
  description = "Defender for open-source relational databases の検証対象 PostgreSQL の FQDN"
  value       = try(azurerm_postgresql_flexible_server.this[0].fqdn, null)
}

output "postgresql_defender_state" {
  description = "Azure から読み戻した PostgreSQL の advancedThreatProtectionSettings の state"
  value       = try(azapi_update_resource.postgresql_defender[0].output.properties.state, null)
}

output "cosmosdb_endpoint" {
  description = "Defender for Azure Cosmos DB の検証対象アカウントのエンドポイント"
  value       = try(azurerm_cosmosdb_account.this[0].endpoint, null)
}

output "verify_pricing_command" {
  description = "サブスクリプション単位のプラン状態を確認するコマンド"
  value       = "az security pricing list --query \"value[?contains('StorageAccounts Containers OpenSourceRelationalDatabases CosmosDbs', name)].{name:name,tier:pricingTier,subPlan:subPlan}\" -o table"
}
