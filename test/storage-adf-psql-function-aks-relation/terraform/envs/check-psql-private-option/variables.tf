# ============================================================================
# check-psql-private-option env 入力変数 (機微情報 / 環境固有値のみ)
# それ以外の構成値は locals.tf で管理する。
# ============================================================================

variable "subscription_id" {
  description = "検証を行うサブスクリプションの ID"
  type        = string
}

variable "psql_admin_password" {
  description = "PostgreSQL 管理者パスワード。ADF Linked Service の Basic 認証にも使用する"
  type        = string
  sensitive   = true
}

# ADF Managed Private Endpoint と PostgreSQL Linked Service を作成するか。
# false にすると VNet 統合 PostgreSQL + ManagedVNet ADF の土台だけを作成する。
# (まず土台を apply し、true に切り替えて MPE 作成挙動を単独で観測したい場合に使う)
variable "enable_adf_mpe" {
  description = "ADF の Managed Private Endpoint / PostgreSQL Linked Service を作成するか"
  type        = bool
  default     = true
}
