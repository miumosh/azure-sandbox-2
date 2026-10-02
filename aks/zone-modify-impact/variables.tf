# ============================================================================
# ルート 入力変数
# - 設定値は原則 locals.tf に置き、機微情報 / 検証の主スイッチのみここで受け取る。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "location" {
  description = "リソースのリージョン。3 ゾーンに展開するため AZ 対応リージョンであること"
  type        = string
  default     = "japaneast"
}

variable "system_zones" {
  description = <<-EOT
    既定ノードプール (azurerm_kubernetes_cluster.default_node_pool) の zones。**主スイッチ 1**。

      ["1", "2"]       : 初期状態
      ["1", "2", "3"]  : 変更後
  EOT
  type        = list(string)
  default     = ["1", "2"]
}

variable "user_zones" {
  description = <<-EOT
    ユーザーノードプール (azurerm_kubernetes_cluster_node_pool) の zones。**主スイッチ 2**。

      null             : 初期状態 (非ゾーン = リージョナル配置)
      ["1", "2", "3"]  : 変更後
  EOT
  type        = list(string)
  default     = null
}

variable "use_temporary_name_for_rotation" {
  description = <<-EOT
    temporary_name_for_rotation を設定するか。

    azurerm は zones の変更を「in-place update」として plan するが、apply 時は
    一時ノードプールを作ってノードプールを丸ごと作り直す (rotation)。
    その一時プール名が未設定だと、plan は通るのに apply が次のエラーで失敗する。

      `temporary_name_for_rotation` must be specified when updating any of the following properties

    false にすると「plan は in-place なのに apply できない」ことを再現できる。
  EOT
  type        = bool
  default     = true
}
