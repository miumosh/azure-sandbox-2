# ============================================================================
# ルート 入力変数
# - 設定値は原則 locals.tf に置き、機微情報 / 環境依存値のみここで受け取る。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "ai_services_network_mode" {
  description = <<-EOT
    AI Services のネットワーク公開方式。実測に基づく 3 モード。

      "portal"     : public 有効 + networkAcls.default_action = Allow。
                     AI Foundry ポータル (ai.azure.com) が使える唯一のモード。
                     ネットワーク制限は実質かからない (PE も併存するが
                     インターネットからも到達可能) 点を許容すること。

      "restricted" : public 有効 + default_action = Deny + allowed_client_ips のみ許可。
                     API 利用は許可 IP から可能だが、AI Foundry ポータルは
                     「プライベート ネットワーク アクセスが必要です」となり使用不可。
                     許可 IP を入れても、bypass = AzureServices を足しても変わらない (検証済み)。
                     ポータルを使わず AKS 等から API 利用するだけならこれが最も安全。

      "private"    : public 無効。Private Endpoint 経由のみ。
                     ポータルは VNet 内 (踏み台 VM / VPN) からのみ利用可能。

    いずれのモードでも PE 経由の経路は維持されるため、AKS からの利用は常に可能。
  EOT
  type        = string
  default     = "portal"

  validation {
    condition     = contains(["portal", "restricted", "private"], var.ai_services_network_mode)
    error_message = "ai_services_network_mode は portal / restricted / private のいずれかを指定してください。"
  }
}

variable "allowed_client_ips" {
  description = <<-EOT
    networkAcls の ip_rules に載せるグローバル IP。裸 IP または CIDR
    (/31, /32 は裸 IP で指定すること)。

    ai_services_network_mode = "restricted" のときに許可 IP として機能する。
    "portal" のときは default_action = Allow のため実質意味を持たない
    (設定値は保持される)。"private" のときは networkAcls 自体を作らない。
  EOT
  type        = list(string)
  default     = []
}
