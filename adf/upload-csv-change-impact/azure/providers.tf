# ============================================================================
# upload-csv-change-impact/azure プロバイダ定義
# - ds_src_csv の変更 (エンコード / 改行コード) を実機 ADF で確かめるための自己完結 env。
# - 本番 env / modules には依存しない (パイプライン定義ファイルだけ本番のものを読む)。
# ============================================================================
terraform {
  required_version = "~> 1.15.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.76.0"
    }
    # PostgreSQL Linked Service (V2) を生 ARM JSON で投入するため (本番 module と同じ理由)
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

  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

data "azurerm_client_config" "current" {}
