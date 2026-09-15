output "subscription_id" {
  description = "Azure Subscription ID (use in agic-values.yaml)"
  value       = var.subscription_id
}

output "agic_identity_client_id" {
  description = "AGIC User-Assigned MI Client ID (use in agic-values.yaml)"
  value       = azurerm_user_assigned_identity.agic.client_id
}

output "aks_get_credentials_cmd" {
  description = "Command to configure kubectl context"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_cluster.aks.name}"
}

# ---- 公開検証用 ------------------------------------------------------------
output "appgw_public_ip" {
  description = "AppGW public frontend IP (= A レコードのターゲット)"
  value       = azurerm_public_ip.appgw.ip_address
}

output "test_fqdn" {
  description = "証明書 CN / Ingress host / A レコードが一致する FQDN"
  value       = azurerm_dns_a_record.appgw.fqdn
}

output "test_url" {
  description = "ローカル PC から素の curl / ブラウザで検証する URL (-k 不要が合格条件)"
  value       = "https://${var.dns_record_name}.${var.dns_zone_name}"
}
