# ============================================================================
# ルート 入力変数
# - 設定値は原則 locals.tf に置き、機微情報 / 検証の主スイッチのみここで受け取る。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "location" {
  description = <<-EOT
    リソースのリージョン。
    Availability Zone 対応リージョンでないとそもそも zones を指定できないため、
    japaneast / eastus など AZ 対応リージョンを指定すること。
  EOT
  type        = string
  default     = "japaneast"
}

variable "redis_zones" {
  description = <<-EOT
    Redis キャッシュに割り当てる Availability Zone。**この検証の主スイッチ**。

      ["1"]          : 単一ゾーン (検証の初期状態)
      ["1", "2"]     : 複数ゾーン (ここに変えると plan が replace になるはず)

    制約: ゾーン数は「ノード数 (primary 1 + replica N)」以下でなければならない。
    既定の replicas_per_master = 1 ならノードは 2 つなので、指定できるゾーンは最大 2 つ。
    3 ゾーンを試したい場合は locals.tf の replicas_per_master を 2 に上げること。

    なお azurerm プロバイダでは zones は ForceNew 属性のため、値を変えると
    Terraform は必ず「破棄 -> 再作成」を計画する。これを実証するのが目的。
  EOT
  type        = list(string)
  default     = ["1"]

  validation {
    condition     = length(var.redis_zones) > 0
    error_message = "redis_zones には最低 1 つのゾーンを指定してください (非ゾーン構成はこの検証の対象外)。"
  }
}
