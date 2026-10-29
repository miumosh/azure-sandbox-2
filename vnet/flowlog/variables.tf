# ============================================================================
# ルート 入力変数
# - 設定値は原則 locals.tf に置き、機微情報 / 検証の主スイッチのみここで受け取る。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "location" {
  description = "リソースのリージョン。フローログの保存先ストレージは VNet と同じリージョンである必要がある"
  type        = string
  default     = "japaneast"
}

variable "storage_public_network_access" {
  description = <<-EOT
    フローログ保存先ストレージの publicNetworkAccess。

      Disabled (既定) : パブリックエンドポイントへのアクセスを全面的に遮断する。
                        ただし network_rules.bypass = ["AzureServices"] (信頼された Azure サービスの例外) は
                        Disabled でも有効なまま残る仕様のため、Network Watcher は書き込める
      Enabled         : network_rules (default_action = Deny) で絞る。ポータルの
                        "Enabled from selected virtual networks and IP addresses" に相当し、
                        Network Watcher FAQ が案内している構成
  EOT
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "Enabled"], var.storage_public_network_access)
    error_message = "storage_public_network_access は Disabled か Enabled を指定してください。"
  }
}

variable "storage_bypass_azure_services" {
  description = "network_rules.bypass に AzureServices を入れるか。false にすると Network Watcher が書き込めなくなることを確認できる"
  type        = bool
  default     = true
}

variable "allowed_client_ips" {
  description = <<-EOT
    storage_public_network_access = "Enabled" のときにログ (Blob) の閲覧を許可する接続元のグローバル IP。
    Disabled のときは無視される (パブリック経由ではどの IP からも読めない)
  EOT
  type        = list(string)
  default     = []
}

variable "network_watcher" {
  description = <<-EOT
    フローログを作成する既存の Network Watcher。Network Watcher はサブスクリプション × リージョンで 1 つだけで、
    通常は自動作成された NetworkWatcherRG / NetworkWatcher_<region> がある。
    確認: az network watcher list -o table
  EOT
  type = object({
    name                = optional(string)
    resource_group_name = optional(string, "NetworkWatcherRG")
  })
  default = {}
}

variable "create_test_vm" {
  description = "フローログに記録させるトラフィックの発生源として VM を作るか (VM 起動時のパッケージ更新などの通信が記録される)"
  type        = bool
  default     = true
}
