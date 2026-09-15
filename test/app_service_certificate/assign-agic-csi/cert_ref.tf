# ===========================================================================
# cert/ の KeyVault を data 参照し、CSI アドオン Identity に読み取り許可を与える (方式B)
# 証明書自体は CSI がランタイムに読むため、ここでは secret の plan 時読み取りはしない。
# ===========================================================================
variable "cert_kv_name" {
  description = "cert/ の output key_vault_name"
  type        = string
}

variable "cert_kv_rg" {
  description = "cert/ の output key_vault_resource_group"
  type        = string
}

variable "cert_secret_name" {
  description = "cert/ の output certificate_secret_name (SecretProviderClass の objectName)"
  type        = string
  default     = "appgw-tls-cert"
}

data "azurerm_key_vault" "cert" {
  name                = var.cert_kv_name
  resource_group_name = var.cert_kv_rg
}

# CSI アドオンの UserAssigned Identity に KeyVault Get を付与
resource "azurerm_key_vault_access_policy" "csi" {
  key_vault_id            = data.azurerm_key_vault.cert.id
  tenant_id               = data.azurerm_key_vault.cert.tenant_id
  object_id               = azurerm_kubernetes_cluster.aks.key_vault_secrets_provider[0].secret_identity[0].object_id
  secret_permissions      = ["Get"]
  certificate_permissions = ["Get"]
}

# ===========================================================================
# ★方式B を成立させるための「KV 証明書オブジェクトへの import」
#
# 【なぜ必要か — これが方式B 最大のハマりどころ】
# App Service Certificate は KV に「証明書オブジェクト」を作らず、
# 素のシークレットに base64 の PFX を入れるだけ (cert/README.md 参照)。
#
# CSI の Azure プロバイダは、KV に「証明書オブジェクト」がある場合にだけ
# PKCS12 → PEM 変換をしてくれる。素のシークレットだと変換されず、
# 代わりに CSI ドライバ側が PKCS12 を解釈することになる。すると Go の
# pkcs12.ToPEM がバッグ属性をそのまま PEM ヘッダとして出力してしまい、
# tls.crt のリーフ証明書がこうなる:
#
#     -----BEGIN CERTIFICATE-----
#     localKeyId: 01000000          ← OpenSSL は Proc-Type 以外のヘッダを解釈できない
#
#     MIIHnjCCBYag...
#
# しかもチェーンが逆順 (ルートが先頭・リーフが最後) で出る。
# 結果、AGIC が tls.crt + tls.key から PFX を作り直す段階で失敗する:
#
#     Code="ErrorExportingWithOpenSSL"
#     "No cert in -in file '/tmp/appgw-ingress-cert...' matches private key"
#
# → そこで、ASC のシークレット値 (= base64 PFX) を KV に「証明書オブジェクト」として
#   import し直す。CSI プロバイダがネイティブに扱えるようになり、クリーンな PEM が出る。
#
# 【トレードオフ (重要)】
# これは *スナップショットのコピー* である。App Service Certificate が更新されると
# 元のシークレット (appgw-tls-cert) は自動更新されるが、この import 済み証明書は
# **自動追従しない** (terraform apply し直しが必要)。
#
# 一方 方式A は AppGW が versionless secret id で KV を直接見るため自動追従する。
# → 「App Service Certificate を使うなら方式A が素直」という結論の根拠。
# ===========================================================================

# ASC が KV に置いたシークレット (値は base64 エンコードされた PFX)
data "azurerm_key_vault_secret" "asc_pfx" {
  name         = var.cert_secret_name
  key_vault_id = data.azurerm_key_vault.cert.id
}

# 同じ PFX を「KV 証明書オブジェクト」として import (別名)
# azurerm_key_vault_certificate の certificate.contents は base64 の PFX を期待しており、
# ASC のシークレット値がまさにそれなので、秘密鍵をディスクに書き出さずそのまま渡せる。
resource "azurerm_key_vault_certificate" "pem" {
  name         = local.csi_cert_name
  key_vault_id = data.azurerm_key_vault.cert.id

  certificate {
    contents = data.azurerm_key_vault_secret.asc_pfx.value
    password = "" # ASC の PFX はパスワード空
  }
}

locals {
  # CSI (SecretProviderClass) が読む KV オブジェクト名。
  # cert/ の元シークレット (var.cert_secret_name) とは別名にして、元を汚さない。
  csi_cert_name = "${var.cert_secret_name}-pem"
}

# SecretProviderClass に埋める値
output "csi_identity_client_id" {
  description = "SecretProviderClass の userAssignedIdentityID"
  value       = azurerm_kubernetes_cluster.aks.key_vault_secrets_provider[0].secret_identity[0].client_id
}

output "keyvault_name" {
  value = data.azurerm_key_vault.cert.name
}

output "tenant_id" {
  value = data.azurerm_key_vault.cert.tenant_id
}

output "csi_cert_object_name" {
  description = "SecretProviderClass の objectName (KV 証明書オブジェクトとして import した方)"
  value       = azurerm_key_vault_certificate.pem.name
}
