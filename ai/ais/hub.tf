# ============================================================================
# AI Foundry Hub (v1) + そのバックエンド Storage / Key Vault
# ----------------------------------------------------------------------------
# var.enable_foundry_hub = true のときだけ作る。
#
# ここは「AI Foundry が利用する Storage Account との紐づけ」「Key Vault の Secret」
# を実際に確認するための部分。v2 (kind = AIServices アカウント) だけで済ませるなら
# Hub / Storage / Key Vault はまるごと不要になる (README §5.1)。
#
# 閉域化の可否は var.hub_dependencies_private で A/B する。
# ============================================================================
locals {
  hub_count = var.enable_foundry_hub ? 1 : 0
}

# ---- Key Vault -------------------------------------------------------------
# Hub の必須依存。Hub は「Entra ID 認証でない connection」の資格情報をここに
# Secret として書き込む。Entra ID ベースの connection なら Secret は作られない。
resource "azurerm_key_vault" "this" {
  count = local.hub_count

  name                = local.key_vault_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # アクセスポリシーではなく RBAC で権限管理する
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7

  # 閉域化する場合は public を閉じ、PE 経由のみにする。
  # Hub / Project の MSI からの書き込みは信頼済みサービス経路 (bypass) で通す。
  public_network_access_enabled = !local.hub_deps_private

  dynamic "network_acls" {
    for_each = local.hub_deps_private ? [1] : []
    content {
      default_action = "Deny"
      bypass         = "AzureServices"
      ip_rules       = var.allowed_client_ips
    }
  }

  tags = local.tags
}

resource "azurerm_private_endpoint" "key_vault" {
  count = local.hub_count

  name                = "pep-${local.key_vault_name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.this["pe"].id

  private_service_connection {
    name                           = "psc-${local.key_vault_name}"
    private_connection_resource_id = azurerm_key_vault.this[0].id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-${local.key_vault_name}"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["vault"].id]
  }

  tags = local.tags
}

# ---- Storage (Hub のバックエンド) -------------------------------------------
resource "azurerm_storage_account" "hub" {
  count = local.hub_count

  name                     = local.hub_storage_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  https_traffic_only_enabled       = true
  min_tls_version                  = "TLS1_2"
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false

  # Hub (Azure ML) はファイル共有も使うため shared key を残す。
  # false にすると Hub 作成自体が失敗しうる。
  shared_access_key_enabled = true

  public_network_access_enabled = !local.hub_deps_private

  identity {
    type = "SystemAssigned"
  }

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
  }

  # 閉域化する場合も、Hub / Project の MSI が到達できるよう
  # 信頼済み Azure サービス経路 (bypass) は開けておく。
  dynamic "network_rules" {
    for_each = local.hub_deps_private ? [1] : []
    content {
      default_action             = "Deny"
      bypass                     = ["AzureServices"]
      ip_rules                   = var.allowed_client_ips
      virtual_network_subnet_ids = []
    }
  }

  tags = merge(local.tags, { purpose = "AI Foundry Hub backing storage" })

  lifecycle {
    # AI Foundry は Hub に紐付けた Storage へ Studio 用の CORS ルールを自動設定する
    # (https://ai.azure.com / https://ml.azure.com 等)。Terraform 側で管理すると
    # 毎回削除しようとして差分が出続け、適用すると Studio のファイルブラウザが壊れる。
    ignore_changes = [blob_properties[0].cors_rule]
  }
}

# データ面 (コンテナ作成) は PE / ファイアウォールの影響を受ける。
# 閉域化した状態では terraform 実行端末から到達できないため既定で空にしてある。
resource "azurerm_storage_container" "hub" {
  for_each = toset(local.hub_storage_container_names)

  name                  = each.value
  storage_account_id    = azurerm_storage_account.hub[0].id
  container_access_type = "private"
}

# Hub は blob と file の両方を使う。file 側の PE / ゾーンが無いと
# データセットや prompt flow のファイル操作が失敗する。
resource "azurerm_private_endpoint" "hub_storage" {
  for_each = var.enable_foundry_hub ? toset(["blob", "file"]) : toset([])

  name                = "pep-${local.hub_storage_name}-${each.value}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.this["pe"].id

  private_service_connection {
    name                           = "psc-${local.hub_storage_name}-${each.value}"
    private_connection_resource_id = azurerm_storage_account.hub[0].id
    subresource_names              = [each.value]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-${local.hub_storage_name}-${each.value}"
    private_dns_zone_ids = [azurerm_private_dns_zone.this[each.value].id]
  }

  tags = local.tags
}

# ---- AI Foundry Hub / Project ----------------------------------------------
resource "azurerm_ai_foundry" "this" {
  count = local.hub_count

  name                = local.hub_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  storage_account_id = azurerm_storage_account.hub[0].id
  key_vault_id       = azurerm_key_vault.this[0].id

  friendly_name         = "AI Services Private Sandbox Hub"
  description           = "AI サービス閉域化検証用の AI Foundry Hub"
  public_network_access = local.hub_public_network_access

  identity {
    type = "SystemAssigned"
  }

  # 依存 (Storage / Key Vault) を閉じる場合、Hub 側にも送信経路を持たせる。
  # 「Storage だけ閉じる」が一番壊れやすいため、閉じるなら managed VNet とセットにする。
  dynamic "managed_network" {
    for_each = local.hub_managed_network_isolation_mode == null ? [] : [local.hub_managed_network_isolation_mode]
    content {
      isolation_mode = managed_network.value
    }
  }

  tags = local.tags

  depends_on = [
    azurerm_private_endpoint.hub_storage,
    azurerm_private_endpoint.key_vault,
  ]
}

resource "azurerm_ai_foundry_project" "this" {
  count = local.hub_count

  name               = local.hub_project_name
  location           = azurerm_ai_foundry.this[0].location
  ai_services_hub_id = azurerm_ai_foundry.this[0].id

  friendly_name = "AI Services Private Sandbox Project"
  description   = "AI サービス閉域化検証用の AI Foundry Project (v1)"

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# Hub 用 PE。subresource は amlworkspace の 1 種類だが、
# api.azureml.ms と notebooks.azure.net の 2 ゾーンが揃って初めてポータルが機能する。
resource "azurerm_private_endpoint" "hub" {
  count = local.hub_count

  name                = "pep-${local.hub_name}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.this["pe"].id

  private_service_connection {
    name                           = "psc-${local.hub_name}"
    private_connection_resource_id = azurerm_ai_foundry.this[0].id
    subresource_names              = ["amlworkspace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "pdzg-${local.hub_name}"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.this["azureml"].id,
      azurerm_private_dns_zone.this["azureml_notebooks"].id,
    ]
  }

  tags = local.tags
}

# ---- RBAC について -----------------------------------------------------------
# Hub / Project のマネージド ID への Storage / Key Vault のロール付与は宣言しない。
# AI Foundry (Azure ML workspace) が作成時に自分の MSI へ自動付与するため、
# 同じ割り当てを書くと 409 RoleAssignmentExists になる。
#
# 自動付与される主なもの:
#   Hub MSI     -> Storage Blob Data Contributor / Storage File Data Privileged Contributor,
#                  Key Vault Administrator
#   Project MSI -> 上記 + Storage Account Contributor / Reader / Azure AI Administrator
