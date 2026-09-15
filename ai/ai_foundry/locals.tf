# ============================================================================
# 環境設定値 (object 型の locals で集中管理)
# - 機微情報 / 環境依存値のみ variables.tf (tfvars)。それ以外はここで定義する。
# - 各リソースは local.<plural>.<key>.<attr> 形式で参照する。
# ============================================================================
locals {
  location = "japaneast"
  prefix   = "aifsbx"

  # Storage / Key Vault / AI Services のカスタムサブドメインはグローバル一意のため
  # 乱数サフィックスを付与する (main.tf の random_string.suffix)。
  suffix = random_string.suffix.result

  tags = {
    project = "ai-foundry"
    env     = "sandbox"
  }

  resource_group_name = "${local.prefix}-rg"

  # ---- ネットワーク -------------------------------------------------------
  vnet = {
    name          = "vnet-${local.prefix}"
    address_space = ["10.50.0.0/16"]
  }

  subnets = {
    # Storage / AI Services の Private Endpoint 配置先
    pe = {
      name             = "snet-pe"
      address_prefixes = ["10.50.10.0/24"]
    }
  }

  # Private DNS Zone のリンク先 VNet (モジュールへ map で渡す)。
  # AI Services を呼ぶワークロード (AKS 等) を別 VNet に置く場合は、
  # peering に加えてその VNet もここに追加しないと PE に名前解決できない。
  private_dns_zone_vnet_links = {
    main = azurerm_virtual_network.this.id
  }

  # ---- Key Vault (AI Foundry Hub の必須依存) -------------------------------
  key_vault = {
    name = "kv-${local.prefix}-${local.suffix}"
  }

  # ---- Storage Account ----------------------------------------------------
  # aif  : AI Foundry Hub のバックエンド (Hub が必須とする Storage)
  # data : 検証データ置き場。DNS Zone は aif 側で作成したものを再利用する
  storage_accounts = {
    aif = {
      storage_account_name     = "st${local.prefix}aif${local.suffix}"
      account_replication_type = "LRS"
      container_names          = []
      # Hub を Public にする方針と揃えて Public。Studio のファイルブラウザは
      # ブラウザ→Storage データ面の直接アクセスになるため、ここを閉じると
      # 「Hub は Public なのにデータセットが見えない」状態になる。
      # 閉じる場合は Hub の managed_network (managed VNet) 有効化とセットで行うこと。
      public_network_access_enabled = true
      shared_access_key_enabled     = true
      blob_properties = {
        versioning_enabled           = true
        delete_retention_policy_days = 7
      }
      private_endpoints = ["blob", "file"]
      tags = {
        purpose = "AI Foundry Hub backing storage"
      }
    }

    data = {
      storage_account_name     = "st${local.prefix}data${local.suffix}"
      account_replication_type = "LRS"
      container_names          = ["raw-data", "processed-data"]
      # terraform 実行端末からコンテナを作成するため public を有効にしている。
      # false にする場合は PE 経由で到達できる実行環境から apply すること。
      public_network_access_enabled = true
      shared_access_key_enabled     = true
      blob_properties = {
        versioning_enabled           = true
        delete_retention_policy_days = 7
      }
      private_endpoints = ["blob"]
      tags = {
        purpose = "AI Foundry data storage"
      }
    }
  }

  # ---- AI Foundry ---------------------------------------------------------
  # AI Foundry への model deployment 追加は AzureRM 未対応のため、
  # Hub / Project 作成後にポータルまたは az CLI で手動作成すること。
  ai_foundries = {
    main = {
      account_name  = "aif-${local.prefix}-01"
      friendly_name = "AI Foundry Sandbox Hub"
      description   = "AI Foundry sandbox hub (private endpoint 検証用)"

      project_name          = "aifp-${local.prefix}-01"
      project_friendly_name = "AI Foundry Sandbox Project"

      # Hub 自体は AI Foundry ポータルから触れるよう Public のままにする。
      # 閉域化する場合は "Disabled" + サブリソース amlworkspace の PE が必要。
      public_network_access = "Enabled"

      # AI Services (Cognitive Account) の基本方針は「AKS 等 VNet 内のワークロードから
      # PE 経由で呼ぶ」。ただし PE 専用にするとポータルの Playground / Chat が
      # ブラウザ→データ面の直接アクセスになるため到達できず、
      # 「プライベート ネットワーク アクセスが必要です」の警告が出る。
      #
      # そのため var.allowed_client_ips (tfvars) に運用者のグローバル IP を指定した場合のみ
      # public を有効化し、network_acls の Deny + 許可 IP で絞る。
      # PE 経由の経路は network_acls の影響を受けないため、AKS からの利用は常に維持される。
      ai_services_name               = "ais-${local.prefix}-${local.suffix}"
      ai_services_sku_name           = "S0"
      ai_services_local_auth_enabled = true

      # 公開方式は var.ai_services_network_mode (tfvars) で切り替える。詳細は variables.tf。
      # 既定は "portal": AI Foundry ポータルは default_action = Allow でないと
      # 「プライベート ネットワーク アクセスが必要です」で使用できないため (検証済み)。
      ai_services_public_network_access_enabled = var.ai_services_network_mode != "private"
      ai_services_network_acls = var.ai_services_network_mode == "private" ? null : {
        default_action = var.ai_services_network_mode == "portal" ? "Allow" : "Deny"
        bypass         = "AzureServices"
        ip_rules       = var.allowed_client_ips
      }

      # 用途は従来の Cognitive Services 系 (Speech / Vision / Language / Content Safety)。
      # AOAI は別アカウントに分離する方針のため cognitiveservices の 1 ゾーンのみ。
      # このアカウントに OpenAI モデルをデプロイする場合は openai ゾーンの追加が必要。
      ai_services_private_dns_zone_names = [
        "privatelink.cognitiveservices.azure.com",
      ]

      tags = {
        purpose = "AI Foundry hub / project / AI Services"
      }
    }
  }
}
