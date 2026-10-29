# ============================================================================
# フローログ保存先ストレージ
#
# 要件 (vnet-flow-logs-overview):
#   - VNet と同じリージョン / 同じ Entra テナント
#   - Standard (Premium は不可)
#
# ネットワーク制限:
#   - public_network_access = "Disabled" でもよい。network_rules.bypass = ["AzureServices"]
#     (信頼された Azure サービスの例外) は Disabled でも有効なまま残る仕様で、
#     Network Watcher (Microsoft.Network) は信頼された Azure サービスに含まれる
#   - default_action は Deny を明示する。Disabled だけにして default_action = Allow のままだと、
#     Defender for Storage / Advisor が「ネットワーク制限なし」と警告する
# ============================================================================
resource "azurerm_storage_account" "flowlog" {
  name                     = local.storage.name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  public_network_access = var.storage_public_network_access

  network_rules {
    default_action = "Deny"
    bypass         = var.storage_bypass_azure_services ? ["AzureServices"] : ["None"]
    # Disabled のときはパブリック経由のアクセス自体が無いので IP ルールは置かない
    ip_rules = var.storage_public_network_access == "Enabled" ? var.allowed_client_ips : []
  }

  # 共有キー / SAS を使わず Entra ID 認証に限定する (キーが漏れても使えない)
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  tags = local.tags
}

# フローログ (insights-logs-flowlogflowevent コンテナー) の閲覧用 (az storage blob list --auth-mode login)
resource "azurerm_role_assignment" "storage_blob_data_reader" {
  scope                = azurerm_storage_account.flowlog.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = data.azurerm_client_config.current.object_id
}
