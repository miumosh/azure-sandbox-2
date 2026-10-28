# ============================================================================
# ルート 入力変数
# - 設定値は原則 locals.tf に置き、機微情報 / 検証の主スイッチのみここで受け取る。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "location" {
  description = "リソースのリージョン"
  type        = string
  default     = "japaneast"
}

variable "targets" {
  description = <<-EOT
    検証対象ごとの作成スイッチ。false にすると検証用リソースと Defender 有効化の両方を作らない。
    費用を抑えたい場合は対象を絞って apply する (費用の内訳は README 参照)。
  EOT
  type = object({
    storage    = optional(bool, true)
    containers = optional(bool, true)
    postgresql = optional(bool, true)
    cosmosdb   = optional(bool, true)
  })
  default = {}
}

variable "enable_subscription_level_plans" {
  description = <<-EOT
    Storage / PostgreSQL / Cosmos DB の Defender プランをサブスクリプション単位でも有効にするか。

      false (既定) : 検証用に作ったリソースだけをリソース単位で有効化する
      true         : サブスクリプション全体で有効化する (= 既存リソースも課金対象になる)

    Containers はリソース単位の有効化手段が無いため、targets.containers = true なら
    この値に関わらずサブスクリプション単位で有効化する。
  EOT
  type        = bool
  default     = false
}

variable "storage_malware_scanning_cap_gb" {
  description = "Defender for Storage のアップロード時マルウェアスキャンの月間上限 (GB / ストレージアカウント)。従量課金の上限になる"
  type        = number
  default     = 1

  validation {
    condition     = var.storage_malware_scanning_cap_gb >= 1 && floor(var.storage_malware_scanning_cap_gb) == var.storage_malware_scanning_cap_gb
    error_message = "storage_malware_scanning_cap_gb は 1 以上の整数で指定してください (-1 の無制限は検証では使わない)。"
  }
}

variable "postgresql_entra_admin_upn" {
  description = <<-EOT
    PostgreSQL の Entra 管理者にする実行ユーザーの UPN。パスワード認証を無効化するため必須。
    取得: az ad signed-in-user show --query userPrincipalName -o tsv
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.postgresql_entra_admin_upn == null || can(regex("@", var.postgresql_entra_admin_upn))
    error_message = "postgresql_entra_admin_upn には UPN (xxx@yyy) を指定してください。"
  }
}

variable "allowed_client_ips" {
  description = "PostgreSQL / Cosmos DB へ接続を許可する接続元のグローバル IP (アラート検証時にアクセスする端末)。空なら外部から接続不可"
  type        = list(string)
  default     = []
}
