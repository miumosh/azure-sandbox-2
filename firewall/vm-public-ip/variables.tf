# ============================================================================
# 入力変数
# - 設定値は原則 locals.tf に置き、環境依存値のみここで受け取る。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "location" {
  description = "全リソースのリージョン"
  type        = string
  default     = "japaneast"
}

# ----------------------------------------------------------------------------
# インバウンド元 (= 戻りパケットを Public IP から返したい相手)
#
# Azure のルートテーブルは「宛先ベース」でしか分岐できない。
# 外部クライアント -> VM Public IP のインバウンドは Public IP に直接届くが、
# その戻り (VM -> クライアントの Public IP) は 0.0.0.0/0 の UDR に従って
# Firewall へ吸われてしまい、Firewall 側にセッションが無いので破棄される
# (非対称ルーティング)。
# そのため「クライアントの Public IP 宛 = next hop Internet」の UDR を入れて、
# 行きと戻りを同じ Public IP に揃える。
#
# => ここに列挙できない不特定多数からの着信が要件なら、この構成は成立しない。
#    その場合は Firewall DNAT / Load Balancer 方式に切り替える (README 参照)。
# ----------------------------------------------------------------------------
variable "inbound_clients" {
  description = <<-EOT
    VM の Public IP へアクセスしてくる外部クライアントの CIDR。
    キーは UDR / NSG ルールの名前に使うので識別しやすい英数字にする。
    例: { office = "203.0.113.10/32", partner = "198.51.100.0/24" }
  EOT
  type        = map(string)

  validation {
    condition     = !contains(values(var.inbound_clients), "0.0.0.0/0")
    error_message = "0.0.0.0/0 を指定すると全アウトバウンドが Firewall を迂回します。個別の CIDR を指定してください。"
  }
}

# ----------------------------------------------------------------------------
# Firewall を経由させず Public IP から直接出したい宛先 (宛先A / 宛先B)
#
# UDR の address_prefix には CIDR のほか Service Tag も指定できる
# (例: "Storage.japaneast", "AzureMonitor")。宛先が FQDN でしか特定できず
# IP が流動する相手はルートで表現できないため、その場合は Firewall の
# アプリケーションルール (FQDN 許可) 側で処理する。
# ----------------------------------------------------------------------------
variable "direct_destinations" {
  description = <<-EOT
    VM の Public IP から直接インターネットへ出す宛先。CIDR または Service Tag。
    例: { dest_a = "203.0.113.0/24", dest_b = "AzureCloud.japaneast" }
  EOT
  type        = map(string)

  validation {
    condition     = !contains(values(var.direct_destinations), "0.0.0.0/0")
    error_message = "0.0.0.0/0 を指定すると全アウトバウンドが Firewall を迂回します。個別の宛先を指定してください。"
  }
}

variable "service_port" {
  description = "外部に公開する VM 上のサービスポート (検証用 cloud-init は nginx / 80 を起動する)"
  type        = number
  default     = 80
}

variable "allow_ssh_from_clients" {
  description = "inbound_clients からの SSH (22) も許可するか。運用は Bastion 推奨のため既定は false。"
  type        = bool
  default     = false
}

variable "firewall_sku_tier" {
  description = "Azure Firewall の SKU Tier (Basic / Standard / Premium)"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.firewall_sku_tier)
    error_message = "firewall_sku_tier は Basic / Standard / Premium のいずれかです。"
  }
}
