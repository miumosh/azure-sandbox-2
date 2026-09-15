# ============================================================================
# 入力変数
# - 設定値は原則 locals.tf に置き、環境依存値と検証で振りたいツマミのみここ。
# ============================================================================
variable "subscription_id" {
  description = "診断設定を行う (= Activity Log の出力元となる) Subscription ID"
  type        = string
}

variable "location" {
  description = "Log Analytics ワークスペースのリージョン"
  type        = string
  default     = "japaneast"
}

# ----------------------------------------------------------------------------
# 有効化する Activity Log カテゴリ
#
# サブスクリプションスコープで指定できるカテゴリは以下の 8 種で固定。
#   Administrative  : ARM への書き込み操作 (作成/更新/削除)。ロール割り当て等も含む
#   Security        : Microsoft Defender for Cloud が生成するアラート / 推奨
#   ServiceHealth   : Azure 側の障害・計画メンテナンス・ヘルスアドバイザリ
#   ResourceHealth  : 個々のリソースの正常性遷移 (Available / Unavailable / Degraded)
#   Alert           : 従来型アラートの発報
#   Recommendation  : Azure Advisor の推奨
#   Policy          : Azure Policy の評価結果 (audit / deny)
#   Autoscale       : 自動スケールの実行イベント
#
# なお azurerm_monitor_diagnostic_categories データソースは
# サブスクリプションスコープを引けない (リソーススコープ専用) ため、
# 動的取得はできず下記のようにハードコードする必要がある。
# ----------------------------------------------------------------------------
variable "activity_log_categories" {
  description = <<-EOT
    診断設定で有効化する Activity Log のカテゴリ。
    既定は要件の 4 つ (Administrative / Security / ServiceHealth / ResourceHealth)。
  EOT
  type        = list(string)
  default = [
    "Administrative",
    "Security",
    "ServiceHealth",
    "ResourceHealth",
  ]

  validation {
    condition = length(setsubtract(var.activity_log_categories, [
      "Administrative", "Security", "ServiceHealth", "ResourceHealth",
      "Alert", "Recommendation", "Policy", "Autoscale",
    ])) == 0
    error_message = "サブスクリプションスコープで指定できるカテゴリは Administrative / Security / ServiceHealth / ResourceHealth / Alert / Recommendation / Policy / Autoscale のみです。"
  }

  validation {
    condition     = length(var.activity_log_categories) > 0
    error_message = "カテゴリを 1 つ以上指定してください (空だと診断設定の作成が拒否されます)。"
  }
}

variable "log_analytics_retention_in_days" {
  description = "Log Analytics の保持日数。PerGB2018 では 30〜730 で、30 日までは追加課金なし。"
  type        = number
  default     = 30

  validation {
    condition     = var.log_analytics_retention_in_days >= 30 && var.log_analytics_retention_in_days <= 730
    error_message = "log_analytics_retention_in_days は 30〜730 の範囲で指定してください。"
  }
}

variable "log_analytics_daily_quota_gb" {
  description = <<-EOT
    Log Analytics の 1 日あたり取り込み上限 (GB)。サンドボックスの事故防止用。
    -1 で無制限。上限に達した日はその日の残り時間の取り込みが破棄される点に注意。
  EOT
  type        = number
  default     = 1
}
