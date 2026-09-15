# ============================================================================
# 共通基盤: Resource Group / VNet / サブネット
# ============================================================================

# Cognitive のカスタムサブドメイン / Storage / Key Vault 名はグローバル一意のため乱数を付与する
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = local.vnet.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = local.vnet.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "this" {
  for_each = local.subnets

  name                 = each.value.name
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = each.value.address_prefixes

  # PE の NIC にネットワークポリシーを適用しない (既定値を明示)
  private_endpoint_network_policies = "Disabled"

  # Foundry v2 の virtual network injection には
  # Microsoft.App/environments への委任が必須 (agent サブネットのみ)。
  dynamic "delegation" {
    for_each = try(each.value.delegation, null) == null ? [] : [each.value.delegation]
    content {
      name = delegation.value.name
      service_delegation {
        name    = delegation.value.service_name
        actions = delegation.value.actions
      }
    }
  }
}
