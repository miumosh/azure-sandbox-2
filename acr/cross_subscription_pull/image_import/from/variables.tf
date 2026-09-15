variable "subscription_id" {
  description = "サブスクリプション A (ソース ACR) の Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure Region"
  type        = string
  default     = "japaneast"
}

variable "acr_name" {
  description = "ソース ACR 名 (グローバル一意・英数字 5-50 文字)"
  type        = string
}

# to (B) を先に apply し、その output `runner_identity_principal_id` を渡す。
# この principal_id に、ソース ACR への import/read 権限を付与する。
variable "import_runner_principal_id" {
  description = "import 実行 ID (B 側 UAMI 等) の principal_id (to の output から取得)"
  type        = string
}
