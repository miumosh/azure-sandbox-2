# ============================================================================
# ルート (呼び出し元)
# - Resource Group / VNet / Key Vault などの共通基盤 + 各 module 呼び出し。
# - 設定値は locals.tf (object)、機微/環境依存値は variables.tf (tfvars)。
# - 構成: Storage (aif/data) -> AI Foundry Hub/Project + AI Services (PE 閉域)
# ============================================================================

# Storage / Key Vault / AI Services のカスタムサブドメインはグローバル一意のため乱数を付与する
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

  # PE の NIC にネットワークポリシーを適用しない (既定値を明示)
  private_endpoint_network_policies = "Disabled"
}

# ---- Key Vault (AI Foundry Hub の必須依存) ----------------------------------
resource "azurerm_key_vault" "this" {
  name                = local.key_vault.name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # アクセスポリシーではなく RBAC で権限管理する
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  tags = local.tags
}

# ---- Storage: AI Foundry Hub のバックエンド --------------------------------
# Private DNS Zone (blob / file) はこのモジュールで作成し、他モジュールへ再利用させる。
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

  create_private_dns_zone              = true
  private_dns_zone_virtual_network_ids = local.private_dns_zone_vnet_links

  tags = merge(local.tags, local.storage_accounts.aif.tags)
}

# ---- Storage: 検証データ置き場 ---------------------------------------------
# 同一 RG 内で privatelink.blob.core.windows.net は 1 つしか作れないため、
# storage_aif が作成したゾーンを再利用する (create_private_dns_zone = false)。
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

  create_private_dns_zone = false
  private_dns_zone_ids    = module.storage_aif.private_dns_zone_ids

  tags = merge(local.tags, local.storage_accounts.data.tags)
}

# ---- AI Foundry (Hub / Project) + AI Services ------------------------------
module "ai_foundry" {
  source = "./modules/ai_foundry"

  account_name        = local.ai_foundries.main.account_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  # Hub の必須依存
  storage_account_id = module.storage_aif.storage_account_id
  key_vault_id       = azurerm_key_vault.this.id

  friendly_name         = local.ai_foundries.main.friendly_name
  description           = local.ai_foundries.main.description
  public_network_access = local.ai_foundries.main.public_network_access

  project_name          = local.ai_foundries.main.project_name
  project_friendly_name = local.ai_foundries.main.project_friendly_name

  ai_services_name                          = local.ai_foundries.main.ai_services_name
  ai_services_sku_name                      = local.ai_foundries.main.ai_services_sku_name
  ai_services_public_network_access_enabled = local.ai_foundries.main.ai_services_public_network_access_enabled
  ai_services_local_auth_enabled            = local.ai_foundries.main.ai_services_local_auth_enabled
  ai_services_network_acls                  = local.ai_foundries.main.ai_services_network_acls

  # AI Services の PE と、その名前解決用 Private DNS Zone (cognitiveservices / openai / services.ai)
  create_private_endpoint              = true
  private_endpoint_subnet_id           = azurerm_subnet.this["pe"].id
  create_private_dns_zone              = true
  private_dns_zone_names               = local.ai_foundries.main.ai_services_private_dns_zone_names
  private_dns_zone_virtual_network_ids = local.private_dns_zone_vnet_links

  tags = merge(local.tags, local.ai_foundries.main.tags)
}

# ---- RBAC について -----------------------------------------------------------
# Hub のマネージド ID への Storage / Key Vault のロール付与は Terraform では行わない。
# AI Foundry (Azure ML workspace) が作成時に自分の MSI へ自動付与するため、
# 同じ割り当てを宣言すると 409 RoleAssignmentExists になる。
#
# 自動付与される主なロール (apply 後に確認済み):
#   Hub MSI     -> Storage Blob Data Contributor / Storage File Data Privileged Contributor
#                  (storage_aif スコープ)、Key Vault Administrator (Key Vault スコープ)
#   Project MSI -> 上記に加えて Storage Account Contributor / Reader / Azure AI Administrator
#
# 追加の権限 (例: 利用者への Cognitive Services User) が必要になった場合のみ、
# ここに azurerm_role_assignment を明示的に足すこと。
