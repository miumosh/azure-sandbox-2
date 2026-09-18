# ============================================================================
# ルート 出力
# scripts/verify.sh はこの出力を読んで検証を行う。
# ============================================================================
output "subscription_id" {
  value = var.subscription_id
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "key_vault_network_mode" {
  description = "適用中の Key Vault 公開方式 (public / restricted / private)"
  value       = var.key_vault_network_mode
}

output "key_vault" {
  value = {
    id                            = module.key_vault.key_vault_id
    name                          = module.key_vault.key_vault_name
    uri                           = module.key_vault.vault_uri
    public_network_access_enabled = module.key_vault.public_network_access_enabled
    private_endpoint_ip           = module.key_vault.private_endpoint_ip_address
  }
}

output "storage_aif" {
  value = {
    id   = module.storage_aif.storage_account_id
    name = module.storage_aif.storage_account_name
  }
}

output "storage_data" {
  value = {
    id                    = module.storage_data.storage_account_id
    name                  = module.storage_data.storage_account_name
    primary_blob_endpoint = module.storage_data.primary_blob_endpoint
    container             = local.sas_container_name
  }
}

output "ai_foundry" {
  value = {
    hub_id               = module.ai_foundry.ai_foundry_id
    hub_name             = module.ai_foundry.ai_foundry_name
    hub_principal_id     = module.ai_foundry.ai_foundry_identity_principal_id
    hub_public_network   = local.ai_foundry.public_network_access
    hub_private_endpoint = module.ai_foundry.private_endpoint_ip_address
    project_id           = module.ai_foundry.ai_foundry_project_id
    project_name         = module.ai_foundry.ai_foundry_project_name
    project_principal_id = module.ai_foundry.ai_foundry_project_identity_principal_id
  }
}

output "connections" {
  description = "検証対象の接続。id は ARM リソース ID (listsecrets の呼び出しに使う)"
  value = {
    hub_blob_sas = {
      id        = azapi_resource.hub_blob_sas.id
      name      = azapi_resource.hub_blob_sas.name
      auth_type = "SAS"
      scope     = "hub"
    }
    project_blob_sas = {
      id        = azapi_resource.project_blob_sas.id
      name      = azapi_resource.project_blob_sas.name
      auth_type = "SAS"
      scope     = "project"
    }
    project_blob_aad = {
      id        = azapi_resource.project_blob_aad.id
      name      = azapi_resource.project_blob_aad.name
      auth_type = "AAD"
      scope     = "project"
    }
  }
}
