# ============================================================================
# 構成値 (object 型の locals で集中管理)
# - 機微情報 / 環境依存値 / 検証スイッチのみ variables.tf (tfvars)。それ以外はここ。
# - 各リソースは local.<plural>.<key>.<attr> 形式で参照する。
# ============================================================================
locals {
  prefix = "aissbx"

  # Cognitive アカウントのカスタムサブドメイン / Storage / Key Vault 名は
  # グローバル一意のため乱数サフィックスを付与する (main.tf の random_string.suffix)。
  suffix = random_string.suffix.result

  tags = {
    project = "ai-services-private"
    env     = "sandbox"
  }

  resource_group_name = "rg-${local.prefix}"

  # ---- ネットワーク -------------------------------------------------------
  # 172.17.0.0/16 は Docker bridge 予約のため PE 用 VNet には使わないこと (MS Docs)。
  vnet = {
    name          = "vnet-${local.prefix}"
    address_space = ["10.60.0.0/16"]
  }

  subnets = {
    # Private Endpoint 専用
    pe = {
      name             = "snet-pe"
      address_prefixes = ["10.60.10.0/24"]
    }
    # 検証用 Linux VM (az vm run-command で nslookup / curl を実行する)
    jumpbox = {
      name             = "snet-jumpbox"
      address_prefixes = ["10.60.20.0/24"]
    }
    # Azure Bastion 用。名前は "AzureBastionSubnet" 固定・最小 /26。
    bastion = {
      name             = "AzureBastionSubnet"
      address_prefixes = ["10.60.30.0/26"]
    }

    # Foundry v2 の virtual network injection 用。
    # Microsoft.App/environments への委任が必須、最小 /27・推奨 /24。
    # Foundry リソース 1 つにつき専用サブネット 1 つで、共有できない。
    agent = {
      name             = "snet-agent"
      address_prefixes = ["10.60.40.0/24"]
      delegation = {
        name         = "Microsoft.App.environments"
        service_name = "Microsoft.App/environments"
        actions      = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }
    }
  }

  # ==========================================================================
  # Private DNS Zone (この構成の本体)
  # --------------------------------------------------------------------------
  # PE は「Private な宛先を用意する装置」でしかなく、実際に Private を通るかは
  # クライアントの名前解決で決まる。ゾーンが足りないと public 無効の場合は
  # 名前解決できず到達不能、public 有効の場合は黙ってインターネット経由になる。
  #
  # 同一 RG 内で同名ゾーンは 1 つしか作れないため、ここで一元的に定義して
  # 各 PE へ ID を配る (ai/ai_foundry の「1 つ目が作って 2 つ目が再利用」方式より単純)。
  #
  # 出典: https://learn.microsoft.com/azure/private-link/private-endpoint-dns
  # ==========================================================================
  private_dns_zone_names = {
    # --- Foundry Tools (Microsoft.CognitiveServices/accounts, subresource "account") ---
    # 1 アカウントが最大 3 つの公開サフィックスを持ちうる。使うものだけ作ればよいが、
    # 「どの SDK でどのホスト名を引くか」を取り違えると到達不能になるため 3 本とも用意する。
    cognitiveservices = "privatelink.cognitiveservices.azure.com" # Speech / Vision / Language / Content Safety / 各種 REST
    openai            = "privatelink.openai.azure.com"            # Azure OpenAI SDK (<sub>.openai.azure.com)
    services_ai       = "privatelink.services.ai.azure.com"       # Azure AI Inference SDK / Foundry (<sub>.services.ai.azure.com)

    # --- AI Foundry Hub (v1 = Microsoft.MachineLearningServices/workspaces, subresource "amlworkspace") ---
    # 2 本セットで 1 組。notebooks 側が無いとポータルのノートブック / ファイル操作が壊れる。
    azureml           = "privatelink.api.azureml.ms"
    azureml_notebooks = "privatelink.notebooks.azure.net"

    # --- Hub のバックエンド ---
    blob  = "privatelink.blob.core.windows.net" # Storage subresource "blob"
    file  = "privatelink.file.core.windows.net" # Storage subresource "file" (Hub のファイル共有で必要)
    vault = "privatelink.vaultcore.azure.net"   # Key Vault subresource "vault"
  }

  # ゾーンをリンクする VNet。AI サービスを呼ぶワークロード (AKS 等) が別 VNet なら、
  # peering に加えてここにも追加しないと PE に名前解決できない (peering だけでは伝播しない)。
  private_dns_zone_vnet_links = {
    main = azurerm_virtual_network.this.id
  }

  # ==========================================================================
  # AI サービス アカウント
  # --------------------------------------------------------------------------
  # kind ごとに「クライアントが引くホスト名」が違うため、必要なゾーンも違う。
  # dns_zone_keys には local.private_dns_zone_names のキーを指定する。
  # ==========================================================================

  # ai_network_mode からネットワーク設定を導出する。
  # public 無効 (private) のときは networkAcls ブロック自体を作らない。
  #   理由: publicNetworkAccess が上位ゲートであり、閉じている時点で ACL は評価対象外。
  #        ブロックを書かない = Deny ではなく「ARM に送らない」なので実効 Allow 相当だが、
  #        上位が閉じているため公開経路は開かない (ai/ai_foundry README の評価順序を参照)。
  ai_public_network_access_enabled = var.ai_network_mode != "private"

  ai_network_acls = var.ai_network_mode == "private" ? null : {
    default_action = var.ai_network_mode == "portal" ? "Allow" : "Deny"
    ip_rules       = var.allowed_client_ips
    # bypass は kind が OpenAI / AIServices / TextAnalytics 以外だと plan 時エラーになる。
    # Speech (kind = SpeechServices) も同じ設定で回すため、ここでは指定しない。
    bypass = null
  }

  cognitive_accounts = {
    # ---- Speech ------------------------------------------------------------
    # 注意: PE を使うにはカスタムサブドメインが必須で、これは **取り消せない**。
    #       有効化した時点でリージョンエンドポイント (<region>.stt.speech.microsoft.com 等) が
    #       使えなくなり、SDK の初期化を FromSubscription -> FromEndpoint に変える必要がある。
    #       詳細は README §4.2。
    speech = {
      name     = "spch-${local.prefix}-${local.suffix}"
      kind     = "SpeechServices"
      sku_name = "S0"
      # Speech は cognitiveservices サフィックスのみ。
      # (<custom>.cognitiveservices.azure.com が stt/tts のプロキシも兼ねる)
      dns_zone_keys = ["cognitiveservices"]
      tags          = { purpose = "Speech (private endpoint 検証)" }
    }

    # ---- AI Foundry (AI Services) -----------------------------------------
    # kind = AIServices は「それ自体が現行 (v2) の AI Foundry リソース」。
    # allowProjectManagement = true のため Azure が入れ子プロジェクトを自動生成する。
    # 3 つの公開サフィックスすべてを持ちうるのでゾーンも 3 本張る。
    aiservices = {
      name          = "ais-${local.prefix}-${local.suffix}"
      kind          = "AIServices"
      sku_name      = "S0"
      dns_zone_keys = ["cognitiveservices", "openai", "services_ai"]
      tags          = { purpose = "AI Foundry (v2) / AI Services (private endpoint 検証)" }
    }

    # ---- Azure OpenAI ------------------------------------------------------
    # <sub>.openai.azure.com が主エンドポイント。管理系 REST が
    # <sub>.cognitiveservices.azure.com を引くことがあるため 2 本張る。
    openai = {
      name          = "oai-${local.prefix}-${local.suffix}"
      kind          = "OpenAI"
      sku_name      = "S0"
      dns_zone_keys = ["cognitiveservices", "openai"]
      tags          = { purpose = "Azure OpenAI (private endpoint 検証)" }
    }
  }

  # ---- VNet Injection 検証用アカウント (Foundry v2) ---------------------------
  # network_injection は **アカウント作成時にしか設定できない**ため、
  # 既存の ais-* に後付けできない。専用アカウントを別に立てて検証する。
  # var.enable_vnet_injection = false のときは作らない。
  injected_account = {
    name          = "aisinj-${local.prefix}-${local.suffix}"
    kind          = "AIServices"
    sku_name      = "S0"
    dns_zone_keys = ["cognitiveservices", "openai", "services_ai"]
    tags          = { purpose = "Foundry v2 virtual network injection 検証" }
  }

  # ---- AI Foundry v2 プロジェクト -------------------------------------------
  # kind = AIServices のアカウント配下に作る入れ子プロジェクト。
  # これが AI Foundry ポータル (ai.azure.com) で開く対象そのものになる。
  #
  # allowProjectManagement = true なら Azure が既定プロジェクトを自動生成する、という
  # 記述が方々にあるが、今回 (public 無効で作成) は生成されなかったため明示的に作る。
  # 明示的に作っておくほうが Terraform 管理下に入り、destroy が 409 で止まらない利点もある。
  aiservices_project_name = "proj-${local.prefix}"

  # ---- モデルデプロイ (OpenAI アカウント) ------------------------------------
  # コントロールプレーン操作なので public 無効でも terraform から作成できる。
  # モデルは廃止 (Deprecating) になると新規デプロイを受け付けなくなり 400 を返す。
  # 利用可能な版は以下で確認する:
  #   az cognitiveservices account list-models -g <rg> -n <account> \
  #     --query "[?lifecycleStatus=='GenerallyAvailable'].{n:name,v:version,s:join(',',skus[].name)}" -o table
  model_deployment = {
    name          = "gpt-5-4-mini"
    model_name    = "gpt-5.4-mini"
    model_version = "2026-03-17"
    sku_name      = "GlobalStandard"
    sku_capacity  = 10
  }

  # ==========================================================================
  # AI Foundry Hub (v1) とその依存
  # ==========================================================================
  key_vault_name   = "kv-${local.prefix}-${local.suffix}"
  hub_storage_name = "st${local.prefix}hub${local.suffix}"
  hub_name         = "aif-${local.prefix}"
  hub_project_name = "aifp-${local.prefix}"

  # Hub とその依存を閉域化するか (var.hub_dependencies_private の別名)。
  hub_deps_private = var.hub_dependencies_private

  # 閉域化する場合、Hub 自身も public 無効にして PE (amlworkspace) からのみ到達させる。
  hub_public_network_access = local.hub_deps_private ? "Disabled" : "Enabled"

  # Hub の「送信」経路。PE (受信) とは別レイヤーの話。
  #
  # Hub は compute instance / prompt flow / 評価ジョブといった計算リソースを
  # **Microsoft 管理のサブスク内**で動かす。閉じた Storage はあなたの VNet からしか
  # 入れないので、その計算リソースには別の経路が要る。これを有効にすると Azure が
  # Hub 専用のマネージド VNet を作り、依存リソースへマネージド PE を自動で張る。
  #
  # 注意 1: **Hub の「作成」にはこれは不要** (A/B テストで実証済み)。
  #         作成は ARM 操作で Storage のデータ面に触らないため。効くのは実行時。
  # 注意 2: isolation_mode を設定してもマネージド VNet はその場では構築されない
  #         (遅延プロビジョニング)。初回の計算リソース作成時まで status は Inactive。
  #
  # 詳細: docs/07-managed-network.md
  hub_managed_network_isolation_mode = local.hub_deps_private ? "AllowInternetOutbound" : null

  # terraform 実行端末は閉域化後の Storage データ面に到達できないため空にしてある。
  # コンテナが必要なら azapi (ARM コントロールプレーン) 経由で作ること。
  hub_storage_container_names = []

  # ---- 検証用 VM ----------------------------------------------------------
  jumpbox = {
    name           = "vm-${local.prefix}-probe"
    size           = "Standard_B2s"
    admin_username = var.jumpbox_admin_username
    image = {
      publisher = "Canonical"
      offer     = "ubuntu-24_04-lts"
      sku       = "server"
      version   = "latest"
    }
  }

  windows_jumpbox = {
    name           = "vm-${local.prefix}-win"
    size           = "Standard_D2s_v5"
    admin_username = var.jumpbox_admin_username
    image = {
      publisher = "MicrosoftWindowsDesktop"
      offer     = "windows-11"
      sku       = "win11-23h2-pro"
      version   = "latest"
    }
  }

  bastion_name = "bas-${local.prefix}"
}
