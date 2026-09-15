# ============================================================================
# Hub env ルート
# - Resource Group + 各 module 呼び出し + Private Endpoint + outputs を集約する。
# - 設定値は locals.tf (object)、機微/参照は variables.tf (tfvars)。
# - Storage / ADF / Bastion / ACR / Hub VNet を管理する。
# ============================================================================
resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}

# ---- ネットワーク (VNet / サブネット / DNS Zone / ピアリング) ---------------
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

# ---- Storage (アップロード / アーカイブ) ------------------------------------
module "storage" {
  source = "../../modules/storage"

  name                   = local.storage_accounts.main.name
  resource_group_name    = azurerm_resource_group.main.name
  location               = local.location
  tags                   = local.tags
  allowed_upload_ip      = var.allowed_upload_ip
  upload_container_name  = local.storage_accounts.main.upload_container
  archive_container_name = local.storage_accounts.main.archive_container
}

# ---- Container Registry -----------------------------------------------------
module "container_registry" {
  source = "../../modules/container_registry"

  name                          = local.container_registries.main.name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = local.location
  tags                          = local.tags
  public_network_access_enabled = var.acr_public_network_access_enabled
  aks_kubelet_object_id         = var.aks_kubelet_object_id
}

module "acr_pe" {
  source = "../../modules/private_endpoint"

  name                            = "${local.container_registries.main.name}-pe"
  location                        = local.location
  resource_group_name             = azurerm_resource_group.main.name
  subnet_id                       = module.network.subnet_ids["pe_acr"]
  private_connection_resource_id  = module.container_registry.id
  subresource_names               = ["registry"]
  private_service_connection_name = "psc-acr"
  private_dns_zone_ids            = [module.network.dns_zone_ids["acr"]]
  dns_zone_group_name             = "acr-dns-zone-group"
  tags                            = local.tags
}

# ---- 踏み台 VM (public IP + SSH。ローカル直結 / zip ビルド・アップロード) -----
module "jumpbox" {
  source = "../../modules/jumpbox"

  jumpbox_name           = local.jumpboxes.main.name
  resource_group_name    = azurerm_resource_group.main.name
  location               = local.location
  tags                   = local.tags
  jumpbox_subnet_id      = module.network.subnet_ids["jumpbox"]
  jumpbox_vm_size        = local.jumpboxes.main.vm_size
  jumpbox_admin_username = local.jumpboxes.main.admin_username
  jumpbox_admin_password = var.jumpbox_admin_password
}

# ---- Data Factory (Managed VNet + Managed PE + 取込パイプライン) ------------
module "data_factory" {
  # ADF はエントリ単位で制御 (locals で無効時は null)。null を除外して作成する。
  for_each = { for k, v in local.data_factories : k => v if v != null }

  source = "../../modules/data_factory"

  name                = each.value.name
  resource_group_name = azurerm_resource_group.main.name
  location            = local.location
  tags                = local.tags

  # 各リソースは locals の object マップで for_each 拡張する。
  role_assignments          = each.value.roles
  managed_private_endpoints = each.value.managed_private_endpoints
  linked_services           = each.value.linked_services
  datasets                  = each.value.datasets
  pipelines                 = each.value.pipelines
  triggers                  = each.value.triggers
}
