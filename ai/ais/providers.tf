# ============================================================================
# AI サービス閉域化 (Public 無効 + Private Endpoint) 検証用プロバイダ定義
#
# 検証対象:
#   - Speech (kind = SpeechServices)
#   - AI Foundry / AI Services (kind = AIServices)
#   - Azure OpenAI (kind = OpenAI)
#   上記 3 アカウントを public 無効 + PE のみで運用できるかを確認する。
#
# 併せて AI Foundry Hub (v1) + Storage + Key Vault の閉域化も切り替えで検証する。
# 設計判断と実測結果は README.md を参照。
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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5.0"
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
    cognitive_account {
      # 論理削除された Cognitive アカウントが同名再作成を阻害するため destroy 時にパージする
      purge_soft_delete_on_destroy = true
    }
  }

  subscription_id = var.subscription_id
}

# 現在のテナント / サブスクリプション情報 (Key Vault の tenant_id 等で使用)
data "azurerm_client_config" "current" {}
