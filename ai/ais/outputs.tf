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

# ---- Private DNS Zone ------------------------------------------------------
output "private_dns_zones" {
  description = "ゾーン識別子 => ゾーン名。PE が必要とするホスト名と突き合わせて確認する"
  value       = { for k, z in azurerm_private_dns_zone.this : k => z.name }
}

# ---- AI サービス -----------------------------------------------------------
output "ai_network_mode" {
  description = "現在の公開方式 (private / portal / restricted)"
  value       = var.ai_network_mode
}

output "cognitive_accounts" {
  description = <<-EOT
    各アカウントの名前 / エンドポイント / PE のプライベート IP / PE が必要とするホスト名。

    private_endpoint_records は PE が Private DNS Zone に登録した A レコード。
    SDK が引くホスト名がここに載っていれば閉域経路が成立している。
    載っていないホスト名を引くと、public 無効なので到達不能になる。
  EOT
  value = {
    for k, m in module.cognitive : k => {
      name                     = m.name
      kind                     = m.kind
      endpoint                 = m.endpoint
      private_endpoint_ip      = m.private_endpoint_ip_address
      private_endpoint_records = m.private_endpoint_records
    }
  }
}

output "model_deployment_name" {
  value = var.enable_model_deployment ? local.model_deployment.name : null
}

output "vnet_injected_account" {
  description = "Foundry v2 virtual network injection の検証用アカウント"
  value = var.enable_vnet_injection ? {
    name             = module.cognitive_injected[0].name
    endpoint         = module.cognitive_injected[0].endpoint
    injected_subnet  = azurerm_subnet.this["agent"].id
    private_endpoint = module.cognitive_injected[0].private_endpoint_ip_address
  } : null
}

output "aiservices_project" {
  description = "AI Foundry ポータル (ai.azure.com) が開く v2 プロジェクト"
  value = {
    name      = azurerm_cognitive_account_project.aiservices.name
    id        = azurerm_cognitive_account_project.aiservices.id
    endpoints = azurerm_cognitive_account_project.aiservices.endpoints
  }
}

# ---- AI Foundry Hub --------------------------------------------------------
output "foundry_hub" {
  description = "Hub (v1) 一式。enable_foundry_hub = false のときは null"
  value = var.enable_foundry_hub ? {
    hub_name              = azurerm_ai_foundry.this[0].name
    hub_id                = azurerm_ai_foundry.this[0].id
    project_name          = azurerm_ai_foundry_project.this[0].name
    public_network_access = local.hub_public_network_access
    private_endpoint_ip   = azurerm_private_endpoint.hub[0].private_service_connection[0].private_ip_address
    storage_account_name  = azurerm_storage_account.hub[0].name
    storage_public        = azurerm_storage_account.hub[0].public_network_access_enabled
    key_vault_name        = azurerm_key_vault.this[0].name
    key_vault_public      = azurerm_key_vault.this[0].public_network_access_enabled
  } : null
}

# ---- 検証用 VM -------------------------------------------------------------
output "jumpbox_vm_name" {
  description = "verify.sh が az vm run-command を打つ対象"
  value       = var.enable_jumpbox ? azurerm_linux_virtual_machine.jumpbox[0].name : null
}

output "windows_jumpbox_vm_name" {
  description = "Bastion 経由でポータルを確認する Windows VM"
  value       = var.enable_bastion ? azurerm_windows_virtual_machine.jumpbox[0].name : null
}

output "verify_command" {
  description = "閉域経路の確認コマンド"
  value       = var.enable_jumpbox ? "./verify.sh" : "enable_jumpbox = true にして apply してください"
}
