# ============================================================================
# function_app モジュール (汎用 Linux Function App)
# - 構成値はすべて変数化 (既定値 = 現行挙動)。env から注入で上書きできる。
# - app_settings は env で構築したオブジェクトを丸ごと注入する
#   (PSQL_* / WEBSITE_RUN_FROM_PACKAGE 等のアプリ固有設定はモジュールが関知しない)。
# - Private Endpoint (inbound) / Storage PE / DNS Zone / deployments コンテナは呼び出し側 (env) が持つ。
# ============================================================================

# Functions 自身のメタデータ用 Storage Account (既定: 完全閉域 + 共有キー無効)
resource "azurerm_storage_account" "this" {
  name                          = var.storage_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  account_tier                  = var.storage_account_tier
  account_replication_type      = var.storage_account_replication_type
  min_tls_version               = var.storage_min_tls_version
  public_network_access_enabled = var.storage_public_network_access_enabled
  shared_access_key_enabled     = var.storage_shared_access_key_enabled

  tags = var.tags
}

resource "azurerm_service_plan" "this" {
  name                = var.plan_name
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = var.os_type
  sku_name            = var.service_plan_sku

  tags = var.tags
}

# デプロイパッケージ置き場 (deployments コンテナ) と、踏み台 VM ユーザーへの RBAC は env 側に置く。
# コンテナは azapi_resource (ARM コントロールプレーン) で作成する (env 側)。理由は env の該当箇所コメント参照:
# 完全閉域では azurerm_storage_container がデータ面=PE 依存になるため、ARM 経由の azapi で依存を断つ。

resource "azurerm_linux_function_app" "this" {
  name                = var.function_app_name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.this.id

  # AzureWebJobsStorage は既定で MI 接続 (共有キー無効)。MI に Storage Blob/Queue/Table ロールが必要。
  storage_account_name          = azurerm_storage_account.this.name
  storage_uses_managed_identity = var.storage_uses_managed_identity

  https_only                    = var.https_only
  public_network_access_enabled = var.public_network_access_enabled
  virtual_network_subnet_id     = var.subnet_func_integration_id

  identity {
    type = var.identity_type
  }

  site_config {
    application_stack {
      python_version = var.python_version
    }
    ip_restriction_default_action     = var.ip_restriction_default_action
    scm_ip_restriction_default_action = var.scm_ip_restriction_default_action
    vnet_route_all_enabled            = var.vnet_route_all_enabled
    ftps_state                        = var.ftps_state
    http2_enabled                     = var.http2_enabled
  }

  # アプリ設定は env で構築したオブジェクトを丸ごと注入 (FUNCTIONS_WORKER_RUNTIME / PSQL_* /
  # WEBSITE_RUN_FROM_PACKAGE 等)。
  app_settings = var.app_settings

  tags = var.tags
}

# ---- RBAC: Function MI の Storage アクセス (共有キー無効 + 完全閉域のため必須) ----
# AzureWebJobsStorage は blob (ホスト状態/リース/Function キー azure-webjobs-secrets) + queue + table を使う。
# run-from-package の読取も blob ロールで行う。各サブサービスは env 側の PE 経由で到達する。
# 最小権限: AzureWebJobsStorage (ホスト状態/リース/azure-webjobs-secrets) と run-from-package 読取は
# Storage Blob Data Contributor で充足する (コンテナ作成/blob 読み書き削除を含む)。
# ※ MS 文書は Owner も案内するため、環境再構築後に Function キー取得・run-from-package 起動を検証すること。
resource "azurerm_role_assignment" "func_mi_blob" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_function_app.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "func_mi_queue" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_linux_function_app.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "func_mi_table" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_linux_function_app.this.identity[0].principal_id
}

# Function キー (default host key)。AKS は x-functions-key に付与して呼ぶ。
data "azurerm_function_app_host_keys" "this" {
  name                = azurerm_linux_function_app.this.name
  resource_group_name = var.resource_group_name
}
