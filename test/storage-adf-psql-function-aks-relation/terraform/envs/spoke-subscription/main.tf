# ============================================================================
# Spoke env ルート
# - Resource Group + Log Analytics + 各 module 呼び出し + Private Endpoint + outputs。
# - 設定値は locals.tf (object)、機微/参照は variables.tf (tfvars)。
# - PostgreSQL / Functions / AKS / Spoke VNet を管理する。
# - data.azurerm_client_config.current は providers.tf で定義。
# ============================================================================
resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}

# Function 用 Storage Account 名はグローバル一意のため乱数を付与する
resource "random_string" "func_storage" {
  length  = 5
  upper   = false
  special = false
  numeric = true
}

# AKS / Function 用 Log Analytics
resource "azurerm_log_analytics_workspace" "main" {
  name                = local.log_analytics_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# ---- ネットワーク (VNet / サブネット / DNS Zone / ピアリング / NSG) ---------
module "network" {
  source = "../../modules/network"

  resource_group_name = azurerm_resource_group.main.name
  location            = local.location
  tags                = local.tags

  vnet_name               = local.vnet.name
  address_space           = local.vnet.address_space
  subnets                 = local.subnets
  dns_zones               = local.dns_zones
  peerings                = local.peerings
  network_security_groups = local.network_security_groups
}

# ---- PostgreSQL Flexible Server --------------------------------------------
module "postgresql" {
  source = "../../modules/postgresql"

  name                = local.postgresql_servers.main.name
  resource_group_name = azurerm_resource_group.main.name
  location            = local.location
  tags                = local.tags

  administrator_login    = local.psql_admin_login
  administrator_password = var.psql_admin_password
  database_name          = local.psql_database_name

  entra_admin_tenant_id      = data.azurerm_client_config.current.tenant_id
  entra_admin_object_id      = coalesce(var.entra_admin_object_id, data.azurerm_client_config.current.object_id)
  entra_admin_principal_name = var.entra_admin_principal_name
  entra_admin_principal_type = var.entra_admin_principal_type
}

module "psql_pe" {
  source = "../../modules/private_endpoint"

  name                            = "${local.postgresql_servers.main.name}-pe"
  location                        = local.location
  resource_group_name             = azurerm_resource_group.main.name
  subnet_id                       = module.network.subnet_ids["pe_psql"]
  private_connection_resource_id  = module.postgresql.id
  subresource_names               = ["postgresqlServer"]
  private_service_connection_name = "psc-psql"
  private_dns_zone_ids            = [module.network.dns_zone_ids["psql"]]
  dns_zone_group_name             = "psql-dns-zone-group"
  tags                            = local.tags
}

# ---- AKS --------------------------------------------------------------------
module "aks" {
  source = "../../modules/aks"

  name                       = local.aks_clusters.main.name
  dns_prefix                 = local.aks_clusters.main.dns_prefix
  resource_group_name        = azurerm_resource_group.main.name
  location                   = local.location
  tags                       = local.tags
  node_size                  = local.aks_clusters.main.node_size
  node_count                 = local.aks_clusters.main.node_count
  subnet_id                  = module.network.subnet_ids["aks"]
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
}

# terraform 実行プリンシパルへ Function 用 Storage のデータ面ロールを付与。
# storage_use_azuread=true (providers.tf) 下で azurerm がアカウント作成後にデータ面ポーリングを
# 行うため必須。アカウント作成時に有効である必要があるため、アカウントより先に存在する RG スコープで
# 付与する (アカウント・スコープでは間に合わない)。
resource "azurerm_role_assignment" "tf_principal_storage_data" {
  for_each = toset([
    "Storage Blob Data Owner",
    "Storage Queue Data Contributor",
    "Storage Table Data Contributor",
  ])
  scope                = azurerm_resource_group.main.id
  role_definition_name = each.value
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---- Functions (run-from-package) ------------------------------------------
# 設定値は locals.function_apps.main.* に集約 (storage_name / deployments_container / app_settings 含む)。
module "function_app" {
  source = "../../modules/function_app"

  function_app_name = local.function_apps.main.name
  plan_name         = local.function_apps.main.plan_name
  storage_name      = local.function_apps.main.storage_name

  resource_group_name = azurerm_resource_group.main.name
  location            = local.location
  tags                = local.tags

  subnet_func_integration_id = module.network.subnet_ids["func_integration"]

  # アプリ設定 (FUNCTIONS_WORKER_RUNTIME / PSQL_* / WEBSITE_RUN_FROM_PACKAGE) を丸ごと注入。
  app_settings = local.function_apps.main.app_settings

  # PostgreSQL の Private DNS リンク確立後に作成する (元 function.tf の depends_on 相当)。
  # tf_principal_storage_data: Storage アカウント作成時のデータ面ポーリングが AAD ロールを使うため、
  # ロール付与を先行させる。
  depends_on = [module.network, azurerm_role_assignment.tf_principal_storage_data]
}

module "func_pe" {
  source = "../../modules/private_endpoint"

  name                            = "${local.function_apps.main.name}-pe"
  location                        = local.location
  resource_group_name             = azurerm_resource_group.main.name
  subnet_id                       = module.network.subnet_ids["pe_func"]
  private_connection_resource_id  = module.function_app.id
  subresource_names               = ["sites"]
  private_service_connection_name = "psc-func"
  private_dns_zone_ids            = [module.network.dns_zone_ids["func"]]
  dns_zone_group_name             = "func-dns-zone-group"
  tags                            = local.tags
}

# ---- Function 用 Storage の完全閉域化 (blob/queue/table PE) ------------------
# public 無効のため、AzureWebJobsStorage (blob/queue/table) と run-from-package 読取、
# および踏み台 VM からのアップロードはすべて PE 経由で到達する。
module "func_storage_blob_pe" {
  source = "../../modules/private_endpoint"

  name                            = "${local.function_apps.main.name}-st-blob-pe"
  location                        = local.location
  resource_group_name             = azurerm_resource_group.main.name
  subnet_id                       = module.network.subnet_ids["pe_stfunc"]
  private_connection_resource_id  = module.function_app.storage_account_id
  subresource_names               = ["blob"]
  private_service_connection_name = "psc-st-blob"
  private_dns_zone_ids            = [module.network.dns_zone_ids["blob"]]
  dns_zone_group_name             = "blob-dns-zone-group"
  tags                            = local.tags
}

module "func_storage_queue_pe" {
  source = "../../modules/private_endpoint"

  name                            = "${local.function_apps.main.name}-st-queue-pe"
  location                        = local.location
  resource_group_name             = azurerm_resource_group.main.name
  subnet_id                       = module.network.subnet_ids["pe_stfunc"]
  private_connection_resource_id  = module.function_app.storage_account_id
  subresource_names               = ["queue"]
  private_service_connection_name = "psc-st-queue"
  private_dns_zone_ids            = [module.network.dns_zone_ids["queue"]]
  dns_zone_group_name             = "queue-dns-zone-group"
  tags                            = local.tags
}

module "func_storage_table_pe" {
  source = "../../modules/private_endpoint"

  name                            = "${local.function_apps.main.name}-st-table-pe"
  location                        = local.location
  resource_group_name             = azurerm_resource_group.main.name
  subnet_id                       = module.network.subnet_ids["pe_stfunc"]
  private_connection_resource_id  = module.function_app.storage_account_id
  subresource_names               = ["table"]
  private_service_connection_name = "psc-st-table"
  private_dns_zone_ids            = [module.network.dns_zone_ids["table"]]
  dns_zone_group_name             = "table-dns-zone-group"
  tags                            = local.tags
}

# デプロイパッケージ置き場 (deployments コンテナ)。
# Storage は完全閉域 (public 無効 + 共有キー無効) のため、azurerm_storage_container だと
# コンテナ作成が blob エンドポイント=データ面になり、Blob PE への依存 (と PE に到達できる踏み台 VM 上での
# apply 必須) が生まれる。それを避けるため ARM コントロールプレーンで作成する azapi_resource を使う
# (PE 不要・public 無効でも作成可。`terraform apply` をローカルからも実行できる。
#  zip の `az storage blob upload` 自体は依然データ面なので踏み台 VM から行う)。
resource "azapi_resource" "deployments" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = local.function_apps.main.deployments_container
  parent_id = "${module.function_app.storage_account_id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

# 踏み台 VM 上のユーザー (Entra) へ deployments コンテナの書込ロールを付与。
# `az storage blob upload --auth-mode login` でアップロードする。
resource "azurerm_role_assignment" "uploader_blob_contributor" {
  for_each             = toset(var.uploader_principal_ids)
  scope                = azapi_resource.deployments.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}
