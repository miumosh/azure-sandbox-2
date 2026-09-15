# ============================================================================
# ルート 出力
# ============================================================================
output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "private_endpoint_subnet_id" {
  value = azurerm_subnet.this["pe"].id
}

output "key_vault_id" {
  value = azurerm_key_vault.this.id
}

# ---- Storage ---------------------------------------------------------------
output "storage_aif" {
  description = "AI Foundry Hub バックエンド Storage"
  value = {
    id                    = module.storage_aif.storage_account_id
    name                  = module.storage_aif.storage_account_name
    private_endpoint_ips  = module.storage_aif.private_endpoint_ip_addresses
    private_dns_zone_ids  = module.storage_aif.private_dns_zone_ids
    primary_blob_endpoint = module.storage_aif.primary_blob_endpoint
  }
}

output "storage_data" {
  description = "検証データ用 Storage"
  value = {
    id                    = module.storage_data.storage_account_id
    name                  = module.storage_data.storage_account_name
    private_endpoint_ips  = module.storage_data.private_endpoint_ip_addresses
    primary_blob_endpoint = module.storage_data.primary_blob_endpoint
  }
}

# ---- AI Foundry ------------------------------------------------------------
output "ai_foundry" {
  value = {
    hub_id       = module.ai_foundry.ai_foundry_id
    hub_name     = module.ai_foundry.ai_foundry_name
    project_id   = module.ai_foundry.ai_foundry_project_id
    project_name = module.ai_foundry.ai_foundry_project_name
  }
}

output "ai_services" {
  value = {
    id                   = module.ai_foundry.ai_services_id
    name                 = module.ai_foundry.ai_services_name
    endpoint             = module.ai_foundry.ai_services_endpoint
    private_endpoint_ip  = module.ai_foundry.private_endpoint_ip_address
    private_dns_zone_ids = module.ai_foundry.private_dns_zone_ids
  }
}
