# ============================================================================
# AI サービス 3 アカウント (Speech / AIServices / OpenAI)
# ----------------------------------------------------------------------------
# var.ai_network_mode = "private" (既定) では 3 つとも public 無効 + PE のみ。
# kind ごとに必要な Private DNS Zone が違う点が要点 (locals.tf の dns_zone_keys)。
# ============================================================================
module "cognitive" {
  source   = "./modules/cognitive_account"
  for_each = local.cognitive_accounts

  name                = each.value.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  kind     = each.value.kind
  sku_name = each.value.sku_name

  public_network_access_enabled = local.ai_public_network_access_enabled
  network_acls                  = local.ai_network_acls

  # 検証用にキー認証を残している。本番想定では false にして Entra ID + RBAC に寄せる
  # (public を開ける構成では、キー漏洩がそのままインターネット経由の悪用になるため)。
  local_auth_enabled = true

  # kind = AIServices 以外では Azure が書き換えないため false でよいが、
  # AIServices のみ true にしないと毎回 ForceNew になる。
  project_management_enabled = each.value.kind == "AIServices"

  create_private_endpoint    = true
  private_endpoint_subnet_id = azurerm_subnet.this["pe"].id

  # dns_zone_keys で指定したゾーンだけを DNS Zone Group に登録する。
  private_dns_zone_ids = {
    for key in each.value.dns_zone_keys : key => azurerm_private_dns_zone.this[key].id
  }

  tags = merge(local.tags, each.value.tags)
}

# ---- モデルデプロイ --------------------------------------------------------
# ARM コントロールプレーン操作のため public 無効でも terraform から作成できる。
# 「閉域化してもデプロイ管理は Terraform / ポータルから普通にできる」ことの確認も兼ねる。
resource "azurerm_cognitive_deployment" "openai" {
  count = var.enable_model_deployment ? 1 : 0

  name                 = local.model_deployment.name
  cognitive_account_id = module.cognitive["openai"].id

  model {
    format  = "OpenAI"
    name    = local.model_deployment.model_name
    version = local.model_deployment.model_version
  }

  sku {
    name     = local.model_deployment.sku_name
    capacity = local.model_deployment.sku_capacity
  }
}

# ---- VNet Injection 検証用アカウント (Foundry v2) -----------------------------
# 「送信」側の閉域化を v1 (Hub の managed_network) と比較するためのもの。
# network_injection は作成時にしか設定できないので専用アカウントを立てている。
module "cognitive_injected" {
  source = "./modules/cognitive_account"
  count  = var.enable_vnet_injection ? 1 : 0

  name                = local.injected_account.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  kind     = local.injected_account.kind
  sku_name = local.injected_account.sku_name

  public_network_access_enabled = local.ai_public_network_access_enabled
  network_acls                  = local.ai_network_acls
  local_auth_enabled            = true
  project_management_enabled    = true

  # ★ここが v2 の「送信」側。あなたの VNet のサブネットにコンテナが注入される。
  network_injection = {
    scenario  = "agent"
    subnet_id = azurerm_subnet.this["agent"].id
  }

  create_private_endpoint    = true
  private_endpoint_subnet_id = azurerm_subnet.this["pe"].id
  private_dns_zone_ids = {
    for key in local.injected_account.dns_zone_keys : key => azurerm_private_dns_zone.this[key].id
  }

  tags = merge(local.tags, local.injected_account.tags)
}

# ---- AI Foundry v2 プロジェクト ---------------------------------------------
# AI Foundry ポータル (ai.azure.com) が開く対象。v1 Hub とは別系統で、
# ネットワーク制限は親アカウント (kind = AIServices) の設定をそのまま継承する。
resource "azurerm_cognitive_account_project" "aiservices" {
  name                 = local.aiservices_project_name
  location             = azurerm_resource_group.this.location
  cognitive_account_id = module.cognitive["aiservices"].id

  display_name = "AI Services Private Sandbox Project (v2)"
  description  = "閉域化した AI Foundry ポータルの動作確認用"

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# AIServices アカウント側にもモデルを置く。
# ポータルの Playground / Chat が閉域でどこまで動くかを見るために必要
# (デプロイが無いと Playground が開いても試せない)。
resource "azurerm_cognitive_deployment" "aiservices" {
  count = var.enable_model_deployment ? 1 : 0

  name                 = local.model_deployment.name
  cognitive_account_id = module.cognitive["aiservices"].id

  model {
    format  = "OpenAI"
    name    = local.model_deployment.model_name
    version = local.model_deployment.model_version
  }

  sku {
    name     = local.model_deployment.sku_name
    capacity = local.model_deployment.sku_capacity
  }
}

# ---- RBAC について ---------------------------------------------------------
# 閉域化すると「ネットワークは通るが 401/403」の切り分けが重要になるため、
# 実行ユーザーに Cognitive Services User を付けて認証要因を潰しておく。
# (403 = ネットワーク遮断 / 401 = 認証失敗、の判定を成立させるための前提)
resource "azurerm_role_assignment" "current_user_cognitive" {
  for_each = local.cognitive_accounts

  scope                = module.cognitive[each.key].id
  role_definition_name = "Cognitive Services User"
  principal_id         = data.azurerm_client_config.current.object_id
}
