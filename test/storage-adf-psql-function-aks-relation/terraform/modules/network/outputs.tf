output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

# 論理キー -> サブネット ID (env から subnet_ids["pe_psql"] のように参照する)
output "subnet_ids" {
  value = { for k, s in azurerm_subnet.this : k => s.id }
}

# 論理キー -> Private DNS Zone ID (PE の dns_zone_group などに渡す)
output "dns_zone_ids" {
  value = { for k, z in azurerm_private_dns_zone.this : k => z.id }
}

output "dns_zone_names" {
  value = { for k, z in azurerm_private_dns_zone.this : k => z.name }
}
