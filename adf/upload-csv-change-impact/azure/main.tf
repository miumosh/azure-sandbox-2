# ============================================================================
# ds_src_csv 変更検証用 ADF 一式 (Storage / PostgreSQL / Data Factory)
#
# 本番 (hub/spoke) との違い: 検証の対象は Dataset の読み込み挙動だけなので、ネットワークと認証は簡略化する。
#   - ADF は Managed VNet / Managed PE を使わず AutoResolveIntegrationRuntime (public)
#   - PostgreSQL は public access + ファイアウォール、ADF からは Basic (管理者ログイン) 認証
#   - Blob Event Trigger は作らず、run_adf.py がパイプラインを手動実行する
#     (トリガーが渡すのは triggeredFileName だけなので、手動実行でも同じ入力になる)
# ============================================================================
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}

# ---- Storage (アップロード / アーカイブ) ------------------------------------
resource "azurerm_storage_account" "main" {
  name                            = local.storage_account.name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = local.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  # azurerm プロバイダは作成時に共有キーで Blob サービスの応答を確認するため有効のままにする
  # (false だと 403 KeyBasedAuthenticationNotPermitted で apply が失敗する)。
  # ADF / az CLI からのアクセスはどちらも Entra ID (RBAC) で行う。
  shared_access_key_enabled = true

  # 作業端末の IP のみ許可。ADF は MI 認証 + 信頼されたサービスの例外 (AzureServices) で到達する。
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = [var.allowed_ip]
  }

  tags = local.tags
}

resource "azurerm_storage_container" "upload" {
  name                  = local.storage_account.upload_container
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "archive" {
  name                  = local.storage_account.archive_container
  storage_account_id    = azurerm_storage_account.main.id
  container_access_type = "private"
}

# 作業者 (terraform 実行者) が az storage blob upload/download --auth-mode login を使うため
resource "azurerm_role_assignment" "operator_blob" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---- PostgreSQL Flexible Server --------------------------------------------
resource "azurerm_postgresql_flexible_server" "main" {
  name                = local.psql.name
  location            = local.location
  resource_group_name = azurerm_resource_group.main.name

  version    = "16"
  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768

  administrator_login    = local.psql.admin_login
  administrator_password = var.psql_admin_password

  public_network_access_enabled = true

  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true
  }

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  tags = local.tags

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = local.psql.database
  server_id = azurerm_postgresql_flexible_server.main.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# 0.0.0.0 のルール = 「Azure サービスからのアクセスを許可」(AutoResolve IR からの接続用)
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# 作業端末からテーブル作成 (setup-db.sh) と結果確認を行うため
resource "azurerm_postgresql_flexible_server_firewall_rule" "operator" {
  name             = "AllowOperator"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = var.allowed_ip
  end_ip_address   = var.allowed_ip
}

# ---- Data Factory -----------------------------------------------------------
resource "azurerm_data_factory" "main" {
  name                   = local.data_factory_name
  location               = local.location
  resource_group_name    = azurerm_resource_group.main.name
  public_network_enabled = true

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

resource "azurerm_role_assignment" "adf_blob" {
  scope                = azurerm_storage_account.main.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.main.identity[0].principal_id
}

# Linked Service 名は本番と同じ (pipeline.json の Script activity が ls_psql を名前で参照する)
resource "azurerm_data_factory_linked_service_azure_blob_storage" "blob" {
  name                 = "ls_blob"
  data_factory_id      = azurerm_data_factory.main.id
  use_managed_identity = true
  service_endpoint     = azurerm_storage_account.main.primary_blob_endpoint

  depends_on = [azurerm_role_assignment.adf_blob]
}

resource "azapi_resource" "psql_linked_service" {
  type      = "Microsoft.DataFactory/factories/linkedservices@2018-06-01"
  name      = "ls_psql"
  parent_id = azurerm_data_factory.main.id
  # azapi 同梱スキーマが PostgreSQL Linked Service V2 の body を未カバーのため検証を無効化する
  schema_validation_enabled = false

  body = {
    properties = {
      type        = "AzurePostgreSql"
      version     = "2.0"
      annotations = []
      typeProperties = {
        server             = azurerm_postgresql_flexible_server.main.fqdn
        port               = 5432
        database           = local.psql.database
        sslMode            = 3 # 3=Require
        authenticationType = "Basic"
        username           = local.psql.admin_login
        password = {
          type  = "SecureString"
          value = var.psql_admin_password
        }
      }
    }
  }

  depends_on = [azurerm_postgresql_flexible_server_firewall_rule.azure_services]
}

locals {
  linked_service_names = {
    blob = azurerm_data_factory_linked_service_azure_blob_storage.blob.name
    psql = azapi_resource.psql_linked_service.name
  }
}

resource "azurerm_data_factory_custom_dataset" "this" {
  for_each = local.datasets

  name            = each.value.name
  data_factory_id = azurerm_data_factory.main.id
  type            = each.value.type

  linked_service {
    name = local.linked_service_names[each.value.linked_service]
  }

  type_properties_json = each.value.type_properties_json
}

# パイプライン本体は本番の pipeline.json / validation.sql をそのまま使う
resource "azurerm_data_factory_pipeline" "ingest" {
  name            = "pl_csv_ingest"
  data_factory_id = azurerm_data_factory.main.id
  concurrency     = 1
  parameters = {
    triggeredFileName = ""
    validation_sql    = file("${local.pipeline_dir}/queries/validation.sql")
  }
  activities_json = file("${local.pipeline_dir}/pipeline.json")

  depends_on = [azurerm_data_factory_custom_dataset.this]
}
