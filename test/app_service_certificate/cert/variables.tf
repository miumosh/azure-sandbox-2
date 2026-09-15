variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "cert_source" {
  description = <<-EOT
    証明書のソースを切り替える。
      self_signed       … azurerm_key_vault_certificate で自己署名を KV に作成 (無料・即時。配管確認用)
      app_service_order … App Service Certificate を購入し ARM で KV に紐付け (有料・ドメイン検証要)
    どちらのモードでも「同名の KV シークレット」を生成するため、割り当て側 (assign-*) は
    ソースを意識せず data 参照できる。
  EOT
  type        = string
  default     = "self_signed"
  validation {
    condition     = contains(["self_signed", "app_service_order"], var.cert_source)
    error_message = "cert_source は self_signed か app_service_order を指定してください。"
  }
}

variable "resource_group_name" {
  type    = string
  default = "rg-appgw-cert-test"
}

variable "location" {
  type    = string
  default = "japaneast"
}

variable "key_vault_name" {
  description = "Key Vault 名。グローバルで一意である必要あり"
  type        = string
}

variable "key_vault_secret_name" {
  description = "証明書を格納する KV シークレット名。= AppGW/AGIC 側の証明書名"
  type        = string
  default     = "appgw-tls-cert"
}

variable "common_name" {
  description = "証明書のコモンネーム (CN)。両モード共通。例: azure-app-service-cert-check.example.com"
  type        = string
}

# ---- app_service_order モードでのみ使う ------------------------------------
variable "cert_order_name" {
  type    = string
  default = "appgw-cert-order"
}

variable "product_type" {
  description = "Standard もしくは WildCard (order モードのみ)"
  type        = string
  default     = "Standard"
}

# ---------------------------------------------------------------------------
# KV アクセスポリシーを与える 2 つの RP サービスプリンシパル
#
# ポータルで App Service Certificate を作ると KV に「2 つ」の access policy が付く
# (公式 FAQ: "What changes does the App Service certificate creation process make
#  to my existing key vault?" → Microsoft Azure App Service / Microsoft.Azure.CertificateRegistration)
#
# 【重要】証明書の実体 (PFX) を KV に書き込むのは CertificateRegistration の方。
#         App Service (abfa0a7c...) と取り違えると Issued になっても KV に値が入らない。
#
# object id は「RP を登録しないとテナントに SP が生えない」ので、
#   az provider register -n Microsoft.CertificateRegistration --wait
# を先に済ませてから取得すること。
# ---------------------------------------------------------------------------
variable "certificate_registration_rp_object_id" {
  description = <<-EOT
    (order モードのみ・必須) 証明書リセラー RP のサービスプリンシパル object id。
    これが KV に PFX を書き込む主体。
      az ad sp show --id f3c21649-0979-4721-ac85-b0216b2cf413 --query id -o tsv
  EOT
  type        = string
  default     = ""
}

variable "appservice_rp_object_id" {
  description = <<-EOT
    (order モードのみ・任意) App Service RP のサービスプリンシパル object id。
    KV 書き込みには不要だが、ポータル作成時と同じ状態に揃えるため付与する。
      az ad sp show --id abfa0a7c-a6b6-4736-8310-5855508787cd --query id -o tsv
  EOT
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "(order モードのみ) DNS 検証に使う既存 Azure DNS ゾーン名"
  type        = string
  default     = "example.com"
}

variable "dns_zone_resource_group_name" {
  description = "(order モードのみ) 上記 DNS ゾーンの RG"
  type        = string
  default     = "rg-dns"
}

variable "dns_verification_record_name" {
  description = <<-EOT
    (order モードのみ) 検証 TXT レコードのホスト名。

    【ハマりどころ】"@" (= ルートドメイン) 固定。証明書の CN がサブドメイン
    (azure-app-service-cert-check.example.com) でも、TXT はサブドメイン側ではなく
    ルートに置く必要がある。公式ドキュメント (Manual verification) の原文:
      "For domain verification via DNS TXT record for either the root domain
       (for example, contoso.com) or the subdomain (for example, www.contoso.com or
       test.api.contoso.com) and regardless of the certificate SKU, you need to add a
       TXT record at the root domain level. Use @ for the name and the domain
       verification token for the value in your DNS record."
      https://learn.microsoft.com/azure/app-service/configure-ssl-app-service-certificate
  EOT
  type        = string
  default     = "@"
}
