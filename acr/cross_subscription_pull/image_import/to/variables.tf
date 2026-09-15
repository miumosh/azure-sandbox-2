variable "subscription_id" {
  description = "サブスクリプション B (import 先 ACR) の Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure Region"
  type        = string
  default     = "japaneast"
}

variable "acr_name" {
  description = "import 先 ACR 名 (グローバル一意・英数字 5-50 文字)"
  type        = string
}

variable "runner_identity_name" {
  description = "import 実行用 User Assigned Identity 名"
  type        = string
  default     = "acr-import-runner"
}

# ----- ソース (A) 情報 -----
# import コマンド output 組み立て専用 (リソースには影響しない)。
# apply 順は to(B) → from(A) のため、初回は既定値のまま to を apply し、
# from の apply 後に from の output を貼り付けて (任意で) 再 apply すると output が完成する。
variable "source_acr_login_server" {
  description = "ソース ACR (A) のログインサーバー。from output: source_acr_login_server"
  type        = string
  default     = "<SOURCE_ACR>.azurecr.io"
}

variable "source_acr_id" {
  description = "ソース ACR (A) の Resource ID。az acr import の --registry 用。from output: source_acr_id"
  type        = string
  default     = "<SOURCE_ACR_RESOURCE_ID>"
}

variable "sample_image" {
  description = "import するイメージ (repository:tag)。output コマンド組み立て用"
  type        = string
  default     = "hello-world:latest"
}
