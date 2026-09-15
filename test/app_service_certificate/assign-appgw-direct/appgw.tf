# ============================================================
# Public IP for Application Gateway
# Standard_v2 SKU はパブリック IP が必須 (Azure 側の制約)
#
# 本構成は「公開検証」: この Public IP に DNS A レコード
# (azure-app-service-cert-check.example.com → dns.tf) を向け、
# ローカル PC から素の curl / ブラウザで HTTPS を検証する。
# Static なので A レコードのターゲットが後から変わることはない。
# ============================================================
resource "azurerm_public_ip" "appgw" {
  name                = "certdirect-appgw-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ============================================================
# Application Gateway (Standard_v2)
# ============================================================
resource "azurerm_application_gateway" "appgw" {
  name                = "certdirect-appgw"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  # 方式A: AppGW が KeyVault の証明書を直接読むための UserAssigned Identity
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw_kv.id]
  }

  # KeyVault の証明書を AppGW にロード (KeyVault リンク)。AGIC は annotation でこの name を参照する
  ssl_certificate {
    name                = var.cert_secret_name
    key_vault_secret_id = data.azurerm_key_vault_secret.cert.versionless_id
  }

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  # 公開検証のため public frontend のみ。
  # AGIC 側も usePrivateIP: false にして、この frontend にリスナーを張らせる。
  frontend_ip_configuration {
    name                 = "appgw-public-frontend"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  # Placeholder — AGIC が起動後に上書きする
  backend_address_pool {
    name = "placeholder-backend-pool"
  }

  backend_http_settings {
    name                  = "placeholder-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "placeholder-listener"
    frontend_ip_configuration_name = "appgw-public-frontend"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "placeholder-routing-rule"
    rule_type                  = "Basic"
    priority                   = 100
    http_listener_name         = "placeholder-listener"
    backend_address_pool_name  = "placeholder-backend-pool"
    backend_http_settings_name = "placeholder-http-settings"
  }

  # AGIC が管理するフィールドの差分を無視
  #
  # 【重要】ここに挙げ漏れると、次に terraform apply した瞬間に AGIC の設定を
  # Terraform が消しにいく。実際 redirect_configuration の漏れを検証中に踏んだ:
  # ingress の ssl-redirect: "true" で AGIC が作る HTTP→HTTPS リダイレクト設定を
  # Terraform が削除しようとして plan に出た (AGIC が作り直すので両者が奪い合う)。
  lifecycle {
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      http_listener,
      probe,
      request_routing_rule,
      url_path_map,
      tags,
      frontend_port,          # AGIC が HTTPS 用に 443 を自動追加するため競合回避
      redirect_configuration, # ingress の ssl-redirect: "true" で AGIC が追加する
    ]
    # ssl_certificate は「方式A では Terraform が所有」するので ignore しない
    # (KeyVault リンクを TF が張るのがこの方式の要点。方式B とはここが逆)
  }

  # 【重要】KeyVault アクセスポリシーへの明示依存
  #
  # AppGW は「作成時」に ssl_certificate.key_vault_secret_id を実際に読みに行くため、
  # UserAssigned Identity に KV の Get 権限が付いた「後」でなければ作成に失敗する。
  #
  # 暗黙依存だけでは足りない:
  #   - identity_ids → azurerm_user_assigned_identity.appgw_kv (ID があるだけ。権限は無関係)
  #   - key_vault_secret_id → data.azurerm_key_vault_secret.cert (Terraform 実行者の権限で読むだけ)
  # どちらも azurerm_key_vault_access_policy.appgw_kv の完了を待たない。
  # → 明示しないと「権限付与前に AppGW 作成」が起こりうる。AppGW の作成は 10 分以上かかるため
  #    失敗コストが高い。
  depends_on = [azurerm_key_vault_access_policy.appgw_kv]
}
