# ============================================================================
# cognitive_account モジュール 出力
# ============================================================================
output "id" {
  value = azurerm_cognitive_account.this.id
}

output "name" {
  value = azurerm_cognitive_account.this.name
}

output "kind" {
  value = azurerm_cognitive_account.this.kind
}

output "endpoint" {
  description = "アカウントの主エンドポイント。kind によりサフィックスが変わる"
  value       = azurerm_cognitive_account.this.endpoint
}

output "custom_subdomain_name" {
  value = azurerm_cognitive_account.this.custom_subdomain_name
}

output "identity_principal_id" {
  value = azurerm_cognitive_account.this.identity[0].principal_id
}

output "primary_access_key" {
  value     = azurerm_cognitive_account.this.primary_access_key
  sensitive = true
}

output "private_endpoint_id" {
  value = one(azurerm_private_endpoint.this[*].id)
}

output "private_endpoint_ip_address" {
  description = "PE に割り当てられたプライベート IP。VNet 内の nslookup がこの値になれば Private 経路"
  value       = one(azurerm_private_endpoint.this[*].private_service_connection[0].private_ip_address)
}

output "private_endpoint_records" {
  description = <<-EOT
    PE が Private DNS Zone に登録した A レコード (FQDN => プライベート IP)。

    ★ここが閉域化の成否そのもの。
    kind = AIServices の PE は 1 リソースだが、公開サフィックスごとに
    **ipConfiguration が分かれて別々のプライベート IP を持つ** (cognitiveservices /
    openai / services.ai で 3 IP)。ゾーンを 1 本しか張らないと、
    残りのホスト名はレコードが作られず VNet 内から到達できない。

    なお DNS Zone Group を付けた PE の customDnsConfigs は **空になる**
    (Azure が名前解決を引き受けるため)。到達性の確認にはこちらを使う。
  EOT
  value = try({
    for r in flatten([
      for c in azurerm_private_endpoint.this[0].private_dns_zone_configs : c.record_sets
    ]) : r.fqdn => try(r.ip_addresses[0], null)
  }, {})
}
