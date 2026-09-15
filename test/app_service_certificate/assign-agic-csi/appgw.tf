# ============================================================
# Public IP for Application Gateway
# Standard_v2 SKU はパブリック IP が必須 (Azure 側の制約)
#
# 本構成は「公開検証」: この Public IP に DNS A レコード
# (www.azure-app-service-cert-check.example.com → dns.tf) を向け、
# ローカル PC から素の curl / ブラウザで HTTPS を検証する。
# ============================================================
resource "azurerm_public_ip" "appgw" {
  name                = "certcsi-appgw-pip"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ============================================================
# Application Gateway (Standard_v2)
# ============================================================
resource "azurerm_application_gateway" "appgw" {
  name                = "certcsi-appgw"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

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
  # Terraform が消しにいく (方式A の検証で redirect_configuration の漏れを踏んだ)。
  # apply 後は必ず terraform plan で "No changes" を確認すること。
  lifecycle {
    ignore_changes = [
      backend_address_pool,
      backend_http_settings,
      http_listener,
      probe,
      request_routing_rule,
      url_path_map,
      tags,
      frontend_port,          # AGIC が HTTPS 用に 443 を自動追加
      redirect_configuration, # ingress の ssl-redirect: "true" で AGIC が追加する
      ssl_certificate,        # ★方式B ではここが方式A と逆。
      #   AGIC が K8s Secret (CSI 同期) から証明書を AppGW に
      #   アップロードするため、証明書は AGIC 所有。
      #   Terraform は KeyVault リンクを張らない。
    ]
  }
}
