# ============================================================================
# storage モジュール
# アップロード / アーカイブ用 Storage Account + コンテナ + keep blob + SAS。
# - Private Endpoint と ADF への RBAC は呼び出し側 (env / data_factory) が持つ。
# ============================================================================
resource "azurerm_storage_account" "this" {
  name                            = var.name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true

  blob_properties {
    # 同名 (input/ciupload39.csv) が毎回アップロードされる運用のため版管理する。
    versioning_enabled = var.versioning_enabled
    delete_retention_policy {
      days = var.delete_retention_days
    }
  }

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = [var.allowed_upload_ip]
  }

  tags = var.tags
}

resource "azurerm_storage_container" "upload" {
  name                  = var.upload_container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "archive" {
  name                  = var.archive_container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

# input/ archive/ 配下を Storage Explorer で見やすくするための空 blob
resource "azurerm_storage_blob" "upload_keep" {
  name                   = "input/.keep"
  storage_account_name   = azurerm_storage_account.this.name
  storage_container_name = azurerm_storage_container.upload.name
  type                   = "Block"
  source_content         = ""
}

resource "azurerm_storage_blob" "archive_success_keep" {
  name                   = "archive/success/.keep"
  storage_account_name   = azurerm_storage_account.this.name
  storage_container_name = azurerm_storage_container.archive.name
  type                   = "Block"
  source_content         = ""
}

resource "azurerm_storage_blob" "archive_error_keep" {
  name                   = "archive/error/.keep"
  storage_account_name   = azurerm_storage_account.this.name
  storage_container_name = azurerm_storage_container.archive.name
  type                   = "Block"
  source_content         = ""
}

# サービス SAS (Storage Explorer から upload コンテナへ書き込むため)
data "azurerm_storage_account_blob_container_sas" "upload" {
  connection_string = azurerm_storage_account.this.primary_connection_string
  container_name    = azurerm_storage_container.upload.name
  https_only        = true

  start  = formatdate("YYYY-MM-DD'T'hh:mm:ssZ", timestamp())
  expiry = formatdate("YYYY-MM-DD'T'hh:mm:ssZ", timeadd(timestamp(), var.sas_expiry))

  permissions {
    read   = true
    add    = true
    create = true
    write  = true
    delete = false
    list   = true
  }

  ip_address = var.allowed_upload_ip
}
