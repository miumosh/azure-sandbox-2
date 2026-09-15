# ============================================================================
# function_app モジュール 入力変数 (Linux Function App)
# - 構成値はすべて変数化し、既定値 = 現行挙動。env から上書き注入できる。
# - app_settings は env でオブジェクトとして構築し丸ごと注入する
#   (PSQL_* / WEBSITE_RUN_FROM_PACKAGE 等のアプリ固有設定はモジュールが関知しない)。
# ============================================================================
variable "function_app_name" {
  type = string
}

variable "plan_name" {
  type = string
}

variable "storage_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ---- Service Plan -----------------------------------------------------------
variable "os_type" {
  type    = string
  default = "Linux"
}

variable "service_plan_sku" {
  type    = string
  default = "EP1"
}

# ---- Function App -----------------------------------------------------------
variable "python_version" {
  # Functions v4 + EP1(Premium) で利用可能な最新。azure-functions 2.x は 3.13+ 必須。
  # ビルド手順の --python-version と必ず一致させること (README 参照)。
  type    = string
  default = "3.13"
}

variable "subnet_func_integration_id" {
  description = "VNet 統合 (outbound) 用サブネット ID"
  type        = string
}

variable "https_only" {
  type    = bool
  default = true
}

variable "public_network_access_enabled" {
  description = "Function App の受信公開可否。既定 false (受信は PE のみ)"
  type        = bool
  default     = false
}

variable "identity_type" {
  description = "マネージドID 種別。既定 SystemAssigned (MI の principal_id を Storage RBAC に使用)"
  type        = string
  default     = "SystemAssigned"

  validation {
    # 本モジュールは identity_ids を配線していないため、UserAssigned を含む値 (単独 / "SystemAssigned, UserAssigned")
    # は apply 時に identity_ids 必須エラーで失敗する。UAMI を使う場合は identity_ids 変数 + dynamic identity の追加が必要。
    condition     = var.identity_type == "SystemAssigned"
    error_message = "identity_type は 'SystemAssigned' のみ対応 (このモジュールは identity_ids 未配線)。"
  }
}

variable "storage_uses_managed_identity" {
  description = "AzureWebJobsStorage を MI 接続にするか (共有キー無効と整合)"
  type        = bool
  default     = true
}

# -- site_config --
variable "ip_restriction_default_action" {
  type    = string
  default = "Deny"
}

variable "scm_ip_restriction_default_action" {
  type    = string
  default = "Deny"
}

variable "vnet_route_all_enabled" {
  type    = bool
  default = true
}

variable "ftps_state" {
  type    = string
  default = "Disabled"
}

variable "http2_enabled" {
  type    = bool
  default = true
}

# アプリ設定。FUNCTIONS_WORKER_RUNTIME / PSQL_* / WEBSITE_RUN_FROM_PACKAGE 等を
# env 側でオブジェクトとして構築し丸ごと注入する。
variable "app_settings" {
  type    = map(string)
  default = {}
}

# ---- Storage (Functions メタデータ用) ---------------------------------------
variable "storage_account_tier" {
  type    = string
  default = "Standard"
}

variable "storage_account_replication_type" {
  type    = string
  default = "LRS"
}

variable "storage_min_tls_version" {
  type    = string
  default = "TLS1_2"
}

variable "storage_public_network_access_enabled" {
  description = "Storage の受信公開可否。既定 false (完全閉域。アクセスは PE のみ)"
  type        = bool
  default     = false
}

variable "storage_shared_access_key_enabled" {
  description = "Storage の共有キー有効可否。既定 false (入口は Entra RBAC のみ)"
  type        = bool
  default     = false
}
