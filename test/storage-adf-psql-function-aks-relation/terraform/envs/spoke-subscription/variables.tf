# ============================================================================
# Spoke env 入力変数 (機微情報 / 環境固有値 / cross-subscription 参照のみ)
# - それ以外の構成値は locals.tf で object 管理する。
# ============================================================================

variable "subscription_id" {
  description = "Spoke サブスクリプション (ci00-spoke-subscription) の ID"
  type        = string
}

variable "psql_admin_password" {
  description = "PostgreSQL 管理者パスワード (bootstrap / break-glass 用)"
  type        = string
  sensitive   = true
}

# ---- PostgreSQL の Entra ID (AAD) 管理者 -------------------------------------
# この管理者で psql に AAD 接続し、ADF / Function の MI ロールを作成する。

variable "entra_admin_object_id" {
  description = "PostgreSQL の Entra 管理者にする object_id。空なら Terraform 実行プリンシパル"
  type        = string
  default     = ""
}

variable "entra_admin_principal_name" {
  description = "Entra 管理者のログイン名 (UPN 等)。psql に AAD 接続する際の user に使う"
  type        = string
}

variable "entra_admin_principal_type" {
  description = "Entra 管理者の種別 (User / Group / ServicePrincipal)"
  type        = string
  default     = "User"
}

# ---- Hub 側リソースへの参照 (cross-subscription) -----------------------------
# Hub を apply した後 output から取得して tfvars に設定する。
# 未設定の間は VNet ピアリング / Private DNS の Hub リンクは作成されない。

variable "hub_vnet_id" {
  description = "Hub VNet のリソース ID (VNet ピアリング先 / Private DNS リンク先)。未設定なら作成しない"
  type        = string
  default     = ""
}

# ---- Function デプロイ (run-from-package / Portal 手動アップロード) -----------
variable "func_package_name" {
  description = "稼働させる zip の blob 名 (例 api-20260616.zip)。運用者が Portal で deployments コンテナへアップロード後、この値を更新して apply する (自動再起動)。空なら WEBSITE_RUN_FROM_PACKAGE を設定しない"
  type        = string
  default     = ""
}

variable "uploader_principal_ids" {
  description = "踏み台 VM 上でアップロードするユーザー/グループの Entra objectId。deployments コンテナへ Storage Blob Data Contributor を付与する"
  type        = list(string)
  default     = []
}
