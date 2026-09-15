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
# 証明書の CN / k8s/ingress.yaml の host / ここで作る A レコードの FQDN は
# すべて一致している必要がある: azure-app-service-cert-check.example.com
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
  description = "AppGW の Public IP を指す A レコードのホスト名 (= 証明書 CN のサブドメイン部)"
  type        = string
  default     = "azure-app-service-cert-check"
}
