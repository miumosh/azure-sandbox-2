# ============================================================================
# Spoke サブスクリプション (ci00-spoke-subscription) 用プロバイダ定義
# - Azure Database for PostgreSQL / Azure Functions / AKS / Spoke VNet を管理
# ============================================================================
terraform {
  # 最新バージョンに固定し、パッチのみ自動更新 (~> X.Y.Z)
  required_version = "~> 1.15.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.76.0"
    }
    # azapi: 完全閉域 (public 無効) の Storage に deployments コンテナを ARM コントロールプレーンで
    # 作成するために使用 (azurerm_storage_container のデータ面/PE 依存を避ける)。
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.10.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.8.0"
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
  }

  # Spoke サブスクリプション ID
  subscription_id = var.subscription_id

  # 共有キー無効の Storage に対し、プロバイダのデータ面アクセス (作成後のサービス可用性
  # ポーリング等) を Entra(AAD) 認証で行う。KeyBasedAuthenticationNotPermitted 回避。
  # 実行プリンシパルに Storage Blob/Queue/Table Data ロールが必要 (main.tf で RG スコープ付与)。
  storage_use_azuread = true
}

provider "azapi" {}

# 既存 AAD リソース (旧 Easy Auth 構成) の destroy にのみ必要。
# AKS -> Function を Function キー方式に変更したため新規の azuread リソースは無い。
provider "azuread" {}

# 現在のテナント / サブスクリプション情報 (PostgreSQL の Entra 管理者設定などで使用)。
data "azurerm_client_config" "current" {}
