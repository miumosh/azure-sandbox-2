# ===========================================================================
# cert/ が作成した KeyVault 証明書を data 参照し、AppGW に載せる (方式A)
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
  description = "cert/ の output certificate_secret_name (= AppGW ssl_certificate 名)"
  type        = string
  default     = "appgw-tls-cert"
}

data "azurerm_key_vault" "cert" {
  name                = var.cert_kv_name
  resource_group_name = var.cert_kv_rg
}

# plan 時に実体を読む。cert/ 側で証明書が存在 (order は Issued) している必要がある
data "azurerm_key_vault_secret" "cert" {
  name         = var.cert_secret_name
  key_vault_id = data.azurerm_key_vault.cert.id
}

# ---------------------------------------------------------------------------
# AppGW 用 UserAssigned Identity (UAI)
#
# AppGW はこの UAI を使って KeyVault から証明書 (PFX シークレット) を読む。
# appgw.tf の identity ブロックで AppGW 本体に紐付けている。
#
# 【この UAI に絡む権限は 2 系統ある。両方ないと動かない】
#   ① UAI → KeyVault             … 下の access policy (secret Get)。
#                                    AppGW が証明書を「読む」ための権限。
#   ② AGIC → この UAI            … role.tf の azurerm_role_assignment.agic_mi_operator_appgw_kv
#                                    (Managed Identity Operator)。
#                                    AGIC が AppGW を「更新する」ための権限。
#                                    AppGW の PUT ボディにこの UAI 参照が含まれるため、
#                                    ARM が呼び出し元に assign/action を要求する。
#                                    無いと LinkedAuthorizationFailed (403) で
#                                    AGIC が AppGW を一切更新できない。詳細は role.tf のコメント。
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "appgw_kv" {
  name                = "certdirect-appgw-kv-identity"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# ① UAI → KeyVault: AppGW が証明書を読むための許可
# 証明書は KV に「シークレット (PFX)」として入っているので secret Get が本質。
# (App Service Certificate は KV 証明書オブジェクトを作らない。cert/README.md 参照)
resource "azurerm_key_vault_access_policy" "appgw_kv" {
  key_vault_id            = data.azurerm_key_vault.cert.id
  tenant_id               = data.azurerm_key_vault.cert.tenant_id
  object_id               = azurerm_user_assigned_identity.appgw_kv.principal_id
  secret_permissions      = ["Get"]
  certificate_permissions = ["Get"]
}
