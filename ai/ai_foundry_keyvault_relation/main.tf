# ============================================================================
# ルート (呼び出し元)
#
# 構成:
#   RG / VNet / PE 用サブネット / Private DNS Zone 一式
#   -> Key Vault (閉域化スイッチ付き) + Storage (aif / data)
#   -> AI Foundry Hub (インバウンドのみ閉域化) + Project
#   -> Storage への SAS 接続 (connections.tf)
#
# 変数として動かすのは var.key_vault_network_mode のみ。
# それ以外 (Storage / Hub / PE) は固定して交絡要因を作らない。
# ============================================================================

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}

# ---- ネットワーク (Private Endpoint 配置先) ---------------------------------
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

  private_endpoint_network_policies = "Disabled"
}

# ---- Private DNS Zone -------------------------------------------------------
# 同一 RG 内でゾーン名は一意でなければならないため、モジュール側ではなく
# ここでまとめて作り、各モジュールへ ID を配る。
resource "azurerm_private_dns_zone" "this" {
  for_each = local.private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.private_dns_zones

  name                  = "pdzvnl-${each.key}"
  resource_group_name   = azurerm_resource_group.this.name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.key].name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = local.tags
}

# ---- Key Vault (検証の主対象) -----------------------------------------------
module "key_vault" {
  source = "./modules/key_vault"

  key_vault_name      = local.key_vault.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tenant_id           = data.azurerm_client_config.current.tenant_id

  public_network_access_enabled = local.key_vault.public_network_access_enabled
  network_acls                  = local.key_vault.network_acls

  create_private_endpoint    = true
  private_endpoint_subnet_id = azurerm_subnet.this["pe"].id
  private_dns_zone_ids       = [azurerm_private_dns_zone.this["vault"].id]

  tags = local.tags
}

# 検証者自身が Key Vault のシークレット (= 接続の SAS) を確認できるようにする。
# Hub の MSI へのロール付与は AI Foundry が自動で行うため宣言しない
# (宣言すると 409 RoleAssignmentExists になる)。
resource "azurerm_role_assignment" "operator_key_vault_admin" {
  count = var.grant_operator_key_vault_role ? 1 : 0

  scope                = module.key_vault.key_vault_id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---- Storage: AI Foundry Hub のバックエンド --------------------------------
module "storage_aif" {
  source = "./modules/storage"

  storage_account_name = local.storage_accounts.aif.storage_account_name
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location

  account_replication_type      = local.storage_accounts.aif.account_replication_type
  public_network_access_enabled = local.storage_accounts.aif.public_network_access_enabled
  shared_access_key_enabled     = local.storage_accounts.aif.shared_access_key_enabled
  container_names               = local.storage_accounts.aif.container_names
  blob_properties               = local.storage_accounts.aif.blob_properties

  private_endpoints = [
    for type in local.storage_accounts.aif.private_endpoints : {
      type      = type
      subnet_id = azurerm_subnet.this["pe"].id
    }
  ]

  private_dns_zone_ids = {
    blob = azurerm_private_dns_zone.this["blob"].id
    file = azurerm_private_dns_zone.this["file"].id
  }

  tags = merge(local.tags, local.storage_accounts.aif.tags)
}

# ---- Storage: SAS 接続の向き先 ---------------------------------------------
module "storage_data" {
  source = "./modules/storage"

  storage_account_name = local.storage_accounts.data.storage_account_name
  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location

  account_replication_type      = local.storage_accounts.data.account_replication_type
  public_network_access_enabled = local.storage_accounts.data.public_network_access_enabled
  shared_access_key_enabled     = local.storage_accounts.data.shared_access_key_enabled
  container_names               = local.storage_accounts.data.container_names
  blob_properties               = local.storage_accounts.data.blob_properties

  private_endpoints = [
    for type in local.storage_accounts.data.private_endpoints : {
      type      = type
      subnet_id = azurerm_subnet.this["pe"].id
    }
  ]

  private_dns_zone_ids = {
    blob = azurerm_private_dns_zone.this["blob"].id
  }

  tags = merge(local.tags, local.storage_accounts.data.tags)
}

# ---- AI Foundry (Hub / Project) --------------------------------------------
module "ai_foundry" {
  source = "./modules/ai_foundry"

  account_name        = local.ai_foundry.account_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  storage_account_id = module.storage_aif.storage_account_id
  key_vault_id       = module.key_vault.key_vault_id

  friendly_name         = local.ai_foundry.friendly_name
  description           = local.ai_foundry.description
  public_network_access = local.ai_foundry.public_network_access

  project_name          = local.ai_foundry.project_name
  project_friendly_name = local.ai_foundry.project_friendly_name

  # インバウンド閉域化: amlworkspace の Private Endpoint
  create_private_endpoint    = true
  private_endpoint_subnet_id = azurerm_subnet.this["pe"].id
  private_dns_zone_ids = [
    azurerm_private_dns_zone.this["amlapi"].id,
    azurerm_private_dns_zone.this["amlnotebooks"].id,
  ]

  tags = local.tags
}
