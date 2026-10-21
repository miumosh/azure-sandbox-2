# ============================================================================
# ルート 入力変数
# - 設定値は原則 locals.tf に置き、機微情報 / 検証の主スイッチのみここで受け取る。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "location" {
  description = "リソースのリージョン (Managed Redis 対応リージョンであること)"
  type        = string
  default     = "japaneast"
}

variable "maintenance_windows" {
  description = <<-EOT
    Managed Redis のカスタムメンテナンスウィンドウ。**この検証の主スイッチ**。
    時刻はすべて UTC。空リスト [] にするとカスタムスケジュールを解除する (Azure 既定に戻す)。

      day_of_week    : Sunday ... Saturday
      start_hour_utc : 0-23 (正時開始のみ)
      duration_hours : ウィンドウの長さ (時間)。API には "PT<n>H" で渡す

    Azure 側の制約 (https://learn.microsoft.com/azure/redis/scheduled-maintenance + 実機確認):
      - 1 ウィンドウあたり 4 時間以上 24 時間以下   (24h 上限はドキュメント未記載、API エラーで確認)
      - 週 2 ウィンドウ以上 (= 2 曜日以上)
      - 週の合計 18 時間以上
      - 1 曜日に 1 ウィンドウまで                 (ドキュメント未記載、API エラーで確認)
    制約違反は API が 400 で弾くが、plan の時点で気付けるよう validation でも検査する。
  EOT
  type = list(object({
    day_of_week    = string
    start_hour_utc = number
    duration_hours = number
  }))
  default = []

  validation {
    condition = alltrue([
      for w in var.maintenance_windows :
      contains(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"], w.day_of_week)
    ])
    error_message = "day_of_week は Sunday ... Saturday のいずれかを指定してください。"
  }

  validation {
    condition = alltrue([
      for w in var.maintenance_windows : w.start_hour_utc >= 0 && w.start_hour_utc <= 23 && floor(w.start_hour_utc) == w.start_hour_utc
    ])
    error_message = "start_hour_utc は 0-23 の整数で指定してください。"
  }

  validation {
    condition = length(var.maintenance_windows) == 0 || (
      length(var.maintenance_windows) >= 2 &&
      alltrue([for w in var.maintenance_windows : w.duration_hours >= 4 && w.duration_hours <= 24 && floor(w.duration_hours) == w.duration_hours]) &&
      sum([for w in var.maintenance_windows : w.duration_hours]) >= 18
    )
    error_message = "カスタムスケジュールは「週 2 ウィンドウ以上 / 各 4-24 時間 (整数) / 合計 18 時間以上」を満たす必要があります。"
  }

  validation {
    condition     = length(distinct([for w in var.maintenance_windows : w.day_of_week])) == length(var.maintenance_windows)
    error_message = "同じ曜日に複数のウィンドウは設定できません (1 曜日 1 ウィンドウ)。"
  }
}
