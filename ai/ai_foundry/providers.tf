# ============================================================================
# AI Foundry サンドボックス用プロバイダ定義
# - AI Foundry (Hub/Project) + AI Services + Storage を Private Endpoint 前提で構成する
# ============================================================================
terraform {
  # 最新バージョンに固定し、パッチのみ自動更新 (~> X.Y.Z)
  required_version = "~> 1.15.5"

  required_providers {
    # azurerm_ai_foundry / azurerm_ai_foundry_project は 4.11.0 以降で利用可能
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.76.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      # サンドボックス用途のため destroy 時に論理削除済み Key Vault をパージする
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }

  subscription_id = var.subscription_id
}

# 現在のテナント / サブスクリプション情報 (Key Vault の tenant_id 等で使用)。
data "azurerm_client_config" "current" {}
