# ============================================================================
# check-psql-private-option env outputs (確認・検証用)
# ============================================================================

output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "psql_server_name" {
  value = azurerm_postgresql_flexible_server.main.name
}

output "psql_server_id" {
  description = "ADF Managed Private Endpoint の接続先リソース ID"
  value       = azurerm_postgresql_flexible_server.main.id
}

output "psql_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "psql_delegated_subnet_id" {
  description = "PostgreSQL を VNet 注入している委任サブネット ID"
  value       = azurerm_subnet.psql.id
}

output "data_factory_name" {
  value = azurerm_data_factory.main.name
}

output "adf_managed_private_endpoint_state" {
  description = "ADF Managed Private Endpoint の provisioningState / connectionState (enable_adf_mpe=true のとき)"
  value       = var.enable_adf_mpe ? azapi_resource.psql_mpe[0].output.properties : null
}

# ---- 検証手順のヒント -------------------------------------------------------
output "verify_hint" {
  description = "確認手順 (詳細は README.md)"
  value       = <<-EOT
    # 1) ADF Managed Private Endpoint の状態を確認
    az datafactory managed-private-endpoint show \
      --factory-name ${azurerm_data_factory.main.name} \
      --resource-group ${azurerm_resource_group.main.name} \
      --managed-virtual-network-name default \
      --name mpe-psql --subscription ${var.subscription_id}

    # 2) PostgreSQL 側の Private Endpoint 接続要求を確認 (Pending なら承認)
    az network private-endpoint-connection list \
      --id ${azurerm_postgresql_flexible_server.main.id} --subscription ${var.subscription_id}

    # 3) ADF Studio > Manage > Linked services > ls_psql_check > Test connection
    #    (ManagedVnetIR 経由でテスト) を実行して到達可否を確認する
  EOT
}
