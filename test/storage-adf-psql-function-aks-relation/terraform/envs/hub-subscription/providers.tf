# ============================================================================
# Hub サブスクリプション (ci00-hub-subscription) 用プロバイダ定義
# - Storage Account / Data Factory / Bastion / Hub VNet を管理する
# ============================================================================
terraform {
  # 最新バージョンに固定し、パッチのみ自動更新 (~> X.Y.Z)
  required_version = "~> 1.15.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.76.0"
    }
    # azapi: ADF の Azure Database for PostgreSQL リンクサービス (V2/MSI 認証) を
    # 生 ARM JSON で作成するために使用 (azurerm の linked_custom_service バグ回避)。
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.10.0"
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

  # Hub サブスクリプション ID
  subscription_id = var.subscription_id
}

# az CLI 認証を共用 (Hub サブスクリプション)
provider "azapi" {
  subscription_id = var.subscription_id
}
