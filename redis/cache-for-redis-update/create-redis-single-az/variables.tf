# ============================================================================
# 入力変数
# ============================================================================
variable "subscription_id" {
  description = <<-EOT
    デプロイ先の Subscription ID。

    Azure Cache for Redis は退役が進行しており、過去に作成実績が無い
    サブスクリプションでは新規作成がブロックされる。事前に

      ../check-history.sh          過去の作成履歴を調べる (読み取り専用)
      ../check-eligibility.sh      作成可否を確定させる

    で確認しておくこと。詳細は ../creation-eligibility.md を参照。
  EOT
  type        = string
}

variable "location" {
  description = "リージョン。Availability Zone 対応リージョンを指定すること"
  type        = string
  default     = "japaneast"
}

variable "zone" {
  description = <<-EOT
    キャッシュを配置する単一の Availability Zone。

    ★ この値を変更すると Terraform はキャッシュを「破棄 -> 再作成」する
      (azurerm の zones は ForceNew 属性)。再作成の影響範囲は
      ../doc/recreation-impact.md にまとめてある。
  EOT
  type        = string
  default     = "1"

  validation {
    condition     = contains(["1", "2", "3"], var.zone)
    error_message = "zone は \"1\" / \"2\" / \"3\" のいずれかを指定してください。"
  }
}

variable "name_prefix" {
  description = "リソース名の接頭辞"
  type        = string
  default     = "redissaz"
}

variable "capacity" {
  description = "Premium の容量 (1=P1 / 2=P2 / 3=P3 / 4=P4)。P1 が最小かつ最安"
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2, 3, 4], var.capacity)
    error_message = "capacity は 1〜4 を指定してください (Premium は P1〜P4)。"
  }
}
