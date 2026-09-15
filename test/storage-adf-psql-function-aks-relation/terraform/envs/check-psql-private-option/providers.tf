# ============================================================================
# check-psql-private-option env プロバイダ定義
# - 検証専用の自己完結 env。本番 modules には依存しない。
# - PostgreSQL の Managed Private Endpoint を azapi で投入するため azapi を要求する。
# ============================================================================
terraform {
  required_version = "~> 1.15.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.76.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
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

provider "azapi" {}

data "azurerm_client_config" "current" {}
