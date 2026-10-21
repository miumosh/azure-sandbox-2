variable "src_subscription_id" {
  description = "サブスクリプション A (ソース ACR) の Subscription ID"
  type        = string
}

variable "dst_subscription_id" {
  description = "サブスクリプション B (取り込み先 ACR) の Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure Region"
  type        = string
  default     = "japaneast"
}

variable "name_prefix" {
  description = "ACR 名の接頭辞 (英数字のみ)。末尾にランダム文字列を付けてグローバル一意にする"
  type        = string
  default     = "acrimprbac"
}

# import を実行する Entra ユーザ (test-user-01) の object ID
#   az ad user show --id <UPN> --query id -o tsv
variable "operator_object_id" {
  description = "import 実行ユーザ (Entra) の object ID"
  type        = string
}

# ----- 検証用トグル -----
# research.md §6 の 2/3 (片側のロールを外すと失敗するか) を terraform apply で切り替える
variable "assign_src_importer" {
  description = "ソース ACR に Data Importer ロールを付与するか"
  type        = bool
  default     = true
}

variable "assign_dst_importer" {
  description = "取り込み先 ACR に Data Importer ロールを付与するか"
  type        = bool
  default     = true
}

variable "seed_image" {
  description = "ソース ACR に事前投入するイメージ (公開レジストリから az acr import する)"
  type        = string
  default     = "mcr.microsoft.com/hello-world:latest"
}
