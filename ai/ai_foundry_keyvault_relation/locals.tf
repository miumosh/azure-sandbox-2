# ============================================================================
# 環境設定値 (object 型の locals で集中管理)
# - 機微情報 / 環境依存値 / 検証スイッチのみ variables.tf (tfvars)。
# ============================================================================
locals {
  location = "japaneast"
  prefix   = "aifkv"

  suffix = random_string.suffix.result

  tags = {
    project = "ai-foundry-keyvault-relation"
    env     = "sandbox"
    purpose = "key vault 閉域化の影響調査"
  }

  resource_group_name = "${local.prefix}-rg"

  # ---- ネットワーク -------------------------------------------------------
  vnet = {
    name          = "vnet-${local.prefix}"
    address_space = ["10.60.0.0/16"]
  }

  subnets = {
    # Key Vault / Storage / AI Foundry Hub の Private Endpoint 配置先
    pe = {
      name             = "snet-pe"
      address_prefixes = ["10.60.10.0/24"]
    }
  }

  # ---- Private DNS Zone (ルートで一元管理し各モジュールへ ID を配る) -------
  # key は参照用の識別子、value は Azure 固定のゾーン名。
  private_dns_zones = {
    blob         = "privatelink.blob.core.windows.net"
    file         = "privatelink.file.core.windows.net"
    vault        = "privatelink.vaultcore.azure.net"
    amlapi       = "privatelink.api.azureml.ms"
    amlnotebooks = "privatelink.notebooks.azure.net"
  }

  # ---- Key Vault (検証の主対象) -------------------------------------------
  key_vault = {
    name = "kv-${local.prefix}-${local.suffix}"

    # public / restricted は public 有効、private のみ public 無効。
    public_network_access_enabled = var.key_vault_network_mode != "private"

    # networkAcls は 3 モードとも設定する。
    # private のときも「設定は残っているのに評価されない」ことを検証で示すため
    # あえて削除しない。
    network_acls = {
      default_action = var.key_vault_network_mode == "public" ? "Allow" : "Deny"
      bypass         = var.key_vault_trusted_azure_services_bypass ? "AzureServices" : "None"
      ip_rules       = var.allowed_client_ips
    }
  }

  # ---- Storage Account ----------------------------------------------------
  # aif  : AI Foundry Hub のバックエンド (Hub が必須とする Storage)
  # data : SAS 接続 (connection) の向き先となる検証データ置き場
  #
  # どちらも public のままにしている。本検証で動かす変数は Key Vault の
  # 公開方式だけに限定し、Storage 側の到達性を交絡要因にしないため。
  storage_accounts = {
    aif = {
      storage_account_name          = "st${local.prefix}aif${local.suffix}"
      account_replication_type      = "LRS"
      container_names               = []
      public_network_access_enabled = true
      shared_access_key_enabled     = true
      blob_properties = {
        versioning_enabled           = true
        delete_retention_policy_days = 7
      }
      private_endpoints = ["blob", "file"]
      tags = {
        role = "AI Foundry Hub backing storage"
      }
    }

    data = {
      storage_account_name          = "st${local.prefix}data${local.suffix}"
      account_replication_type      = "LRS"
      container_names               = ["sas-target"]
      public_network_access_enabled = true
      # SAS を発行するため共有キーは必須
      shared_access_key_enabled = true
      blob_properties = {
        versioning_enabled           = true
        delete_retention_policy_days = 7
      }
      private_endpoints = ["blob"]
      tags = {
        role = "SAS connection target"
      }
    }
  }

  # ---- AI Foundry ---------------------------------------------------------
  ai_foundry = {
    account_name  = "aif-${local.prefix}-01"
    friendly_name = "AI Foundry KeyVault Relation Sandbox"
    description   = "Key Vault 閉域化が Storage SAS 接続に与える影響の検証用 Hub"

    project_name          = "aifp-${local.prefix}-01"
    project_friendly_name = "KeyVault Relation Project"

    # 前提: インバウンドのみ閉域化 (public 無効 + amlworkspace PE)。
    # アウトバウンド (managed VNet / VNet 統合) は一切設定しない。
    public_network_access = var.ai_foundry_public_network_access
  }

  # ---- 検証用の接続 (connection) ------------------------------------------
  # SAS の向き先コンテナ。SAS 接続 2 本 + 対照群の AAD 接続 1 本を作る。
  sas_container_name = "sas-target"

  connections = {
    # Hub 直下の SAS 接続 (Project へ共有される)
    hub_sas = {
      name      = "conn-blob-sas-hub"
      auth_type = "SAS"
      scope     = "hub"
    }
    # Project 直下の SAS 接続
    project_sas = {
      name      = "conn-blob-sas-project"
      auth_type = "SAS"
      scope     = "project"
    }
    # 対照群: シークレットを持たない Entra ID (AAD) 接続。
    # Key Vault にシークレットを置かないため、閉域化の影響を受けないはず。
    project_aad = {
      name      = "conn-blob-aad-project"
      auth_type = "AAD"
      scope     = "project"
    }
  }
}
