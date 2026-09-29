# ============================================================================
# 入力変数 (機微情報 / 環境固有値のみ)。それ以外の構成値は locals.tf で管理する。
# ============================================================================

variable "subscription_id" {
  description = "検証を行うサブスクリプションの ID"
  type        = string
}

variable "allowed_ip" {
  description = "Storage / PostgreSQL へ接続する作業端末のグローバル IP (裸 IP。例: 203.0.113.10)"
  type        = string
}

variable "psql_admin_password" {
  description = "PostgreSQL 管理者パスワード。ADF Linked Service の Basic 認証とテーブル作成にも使用する"
  type        = string
  sensitive   = true
}

variable "src_csv_dataset" {
  description = "ds_src_csv に使う定義。after = 変更後 (UTF-8 / CRLF)、before = 変更前 (shift_jis / LF)"
  type        = string
  default     = "after"

  validation {
    condition     = contains(["after", "before"], var.src_csv_dataset)
    error_message = "src_csv_dataset は after または before。"
  }
}
