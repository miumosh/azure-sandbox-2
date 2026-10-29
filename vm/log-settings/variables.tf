# ============================================================================
# ルート 入力変数
# - 設定値は原則 locals.tf に置き、機微情報 / 検証の主スイッチのみここで受け取る。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "location" {
  description = "リソースのリージョン。DCR は Log Analytics ワークスペースと同じリージョンに作る"
  type        = string
  default     = "japaneast"
}

variable "alert_email_addresses" {
  description = <<-EOT
    アラート (アクショングループ) のメール通知先。個人のアドレスになるため terraform.tfvars (git 管理外) にだけ書く。
    空のときはアクショングループを作らず、アラートは発報してもポータル上の履歴に残るだけになる。
    (count の判定に使うため sensitive にはできない。plan の表示には出るが output には出さない)
  EOT
  type        = list(string)
  default     = []
}

variable "log_analytics_retention_in_days" {
  description = "Log Analytics ワークスペースの既定の保持日数 (30-730)"
  type        = number
  default     = 30
}

variable "log_analytics_daily_quota_gb" {
  description = "サンドボックスでの取り込み事故を防ぐための日次上限 (GB)。無制限にするなら -1"
  type        = number
  default     = 1
}

variable "syslog_log_levels" {
  description = <<-EOT
    Syslog として収集する重要度。AMA の DCR は「最小レベル」ではなく収集するレベルを列挙する。
    Debug まで入れると量が増えるので既定では Info 以上。
  EOT
  type        = list(string)
  default     = ["Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
}
