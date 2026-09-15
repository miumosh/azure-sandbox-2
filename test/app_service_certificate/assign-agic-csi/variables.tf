variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "location" {
  description = "Azure Region"
  type        = string
  default     = "japaneast"
}

# ---- 公開検証用の DNS (既存 Azure DNS ゾーンに A レコードを作る) --------------
#
# 【方式A と同時に動かすための工夫】
# 方式A (assign-appgw-direct) が既に
#   azure-app-service-cert-check.example.com → 方式A の AppGW
# という A レコードを持っている。方式B が同じ名前を使うと衝突する。
#
# 一方、cert/ が発行した証明書の SAN は 2 件ある:
#   DNS:azure-app-service-cert-check.example.com          ← 方式A が使用
#   DNS:www.azure-app-service-cert-check.example.com      ← 方式B はこちらを使う
# (App Service Certificate の Standard SKU は "www 付き" を自動で SAN に含める)
#
# → 方式B は www 側の SAN を使うことで、同じ証明書のまま、方式A を消さずに
#   両方式を同時に公開検証できる。TLS 名の不一致も起きない。
variable "dns_zone_name" {
  description = "AppGW を公開する既存 Azure DNS ゾーン名"
  type        = string
  default     = "example.com"
}

variable "dns_zone_resource_group_name" {
  description = "上記 DNS ゾーンの RG"
  type        = string
  default     = "rg-dns"
}

variable "dns_record_name" {
  description = <<-EOT
    AppGW の Public IP を指す A レコードのホスト名。
    証明書の www 側 SAN に合わせる (方式A の A レコードと衝突させないため)。
  EOT
  type        = string
  default     = "www.azure-app-service-cert-check"
}
