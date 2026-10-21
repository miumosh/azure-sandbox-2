# ============================================================================
# Azure Managed Redis のメンテナンス設定 検証用プロバイダ定義
#
# - azurerm : リソースグループ / Managed Redis 本体
# - azapi   : メンテナンス設定 (maintenanceConfiguration)
#             azurerm_managed_redis には該当属性が無い (v5.10.0 時点) ため azapi で補う
# ============================================================================
terraform {
  required_version = "~> 1.15.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.13.0"
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

  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}
