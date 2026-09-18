# ============================================================================
# Key Vault 閉域化影響検証 用プロバイダ定義
#
# 検証テーマ:
#   AI Foundry (Hub) の Storage 接続 (authType = SAS) は、SAS トークンを
#   Hub に紐付く Key Vault のシークレットとして保持する。
#   その Key Vault を閉域化 (public 無効 / Deny + PE) した際に、
#   AI Foundry 側の接続性にどう影響するかを実測する。
#
# 前提 (ユーザー指定):
#   - AI Foundry は「インバウンドのみ閉域化」(public_network_access = Disabled + PE)
#   - managed VNet / VNet 統合などの「アウトバウンド閉域化」は行わない
#     => AI Foundry の RP / バックエンドから Key Vault への経路は
#        顧客 VNet ではなく Microsoft 管理ネットワーク側から出る
# ============================================================================
terraform {
  required_version = "~> 1.15.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.76.0"
    }
    # AzureRM 未対応の workspace connections (Microsoft.MachineLearningServices/workspaces/connections)
    # を作成するために使用する。
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
    # SAS の start / expiry を固定し、plan のたびに差分が出るのを防ぐ。
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
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

provider "azapi" {
  subscription_id = var.subscription_id
}

data "azurerm_client_config" "current" {}
