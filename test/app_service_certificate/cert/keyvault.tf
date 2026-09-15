resource "azurerm_key_vault" "this" {
  name                       = var.key_vault_name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = false
  soft_delete_retention_days = 7
}

# 実行者 (Terraform) 用: self-signed 作成・確認に必要
resource "azurerm_key_vault_access_policy" "me" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions      = ["Get", "List", "Set", "Delete"]
  certificate_permissions = ["Get", "List", "Create", "Import", "Update", "Delete"]
}

# ===========================================================================
# order モードのみ: RP に KV への権限を付与
#
# ポータルで App Service Certificate を作成すると KV に access policy が「2 つ」付く。
#   - Microsoft.Azure.CertificateRegistration … 証明書リセラー RP。★KV に PFX を書き込む主体★
#   - Microsoft Azure App Service             … App Service RP。KV から証明書を読む側
# ここでも同じ 2 つを付与して、ポータル作成時と同じ状態に揃える。
#
# 【ハマりどころ】KV に書き込むのは CertificateRegistration (appId f3c21649-...) の方。
#   App Service (appId abfa0a7c-...) だけを許可しても、ドメイン検証が通って Issued に
#   なった後も KV シークレットは空 (tag=Initialize) のまま値が入らない。
#
# 証明書の実体は KV に「シークレット (PFX)」として入るため secret_permissions が本質。
# 公式の表は certificate 側にも "Set" と書いているが、KV の certificate 権限に Set は
# 存在せず azurerm の validation で落ちるため、certificate 側は付けない。
# ===========================================================================
resource "azurerm_key_vault_access_policy" "certificate_registration_rp" {
  count = var.cert_source == "app_service_order" ? 1 : 0

  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = var.certificate_registration_rp_object_id

  secret_permissions = ["Get", "List", "Set", "Delete"]
}

resource "azurerm_key_vault_access_policy" "appservice_rp" {
  count = var.cert_source == "app_service_order" && var.appservice_rp_object_id != "" ? 1 : 0

  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = var.appservice_rp_object_id

  secret_permissions = ["Get", "List", "Set", "Delete"]
}
