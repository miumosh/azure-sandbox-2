# ============================================================================
# 検証対象: Defender for Storage
#
# azurerm_security_center_storage_defender でストレージアカウント単位に有効化する
# (Microsoft.Security/defenderForStorageSettings/current)。
# override_subscription_settings_enabled = true にすると、サブスクリプション単位の
# 設定よりこちらが優先される。
# ============================================================================
resource "azurerm_storage_account" "this" {
  count = var.targets.storage ? 1 : 0

  name                     = local.storage.name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # 共有キー / SAS を使わず Entra ID 認証に限定する (キーが漏れても使えない)
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  tags = local.tags
}

resource "azurerm_storage_container" "upload" {
  count = var.targets.storage ? 1 : 0

  name                  = local.storage.container_name
  storage_account_id    = azurerm_storage_account.this[0].id
  container_access_type = "private"

  # provider の storage_use_azuread で Entra 認証するため、ロール付与の伝播を待つ
  depends_on = [azurerm_role_assignment.storage_blob_data_contributor]
}

# テストファイルのアップロード (az storage blob upload --auth-mode login) 用
resource "azurerm_role_assignment" "storage_blob_data_contributor" {
  count = var.targets.storage ? 1 : 0

  scope                = azurerm_storage_account.this[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_security_center_storage_defender" "this" {
  count = var.targets.storage ? 1 : 0

  storage_account_id                     = azurerm_storage_account.this[0].id
  override_subscription_settings_enabled = true

  # アップロード時マルウェアスキャン (GB 単位の従量課金。上限で費用を抑える)
  malware_scanning_on_upload_enabled          = true
  malware_scanning_on_upload_cap_gb_per_month = var.storage_malware_scanning_cap_gb

  # 機密データの検出 (追加料金なし)
  sensitive_data_discovery_enabled = true

  # サブスクリプション単位の設定と同時に作ると後勝ちになりうるため順序を固定する
  depends_on = [azurerm_security_center_subscription_pricing.this]
}
