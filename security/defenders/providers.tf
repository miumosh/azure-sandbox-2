# ============================================================================
# Microsoft Defender for Cloud (Storage / Containers / Databases) 検証用プロバイダ定義
#
# - azurerm : 検証対象リソース一式 + Defender プランの有効化
# - azapi   : PostgreSQL フレキシブルサーバーのリソース単位の Defender 有効化
#             (Microsoft.DBforPostgreSQL/flexibleServers/advancedThreatProtectionSettings)
#             azurerm に相当リソースが無いため azapi で補う
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

  # ストレージアカウントは共有キー認証を無効化するため、データプレーン操作
  # (コンテナー作成など) を Entra ID 認証で行わせる
  storage_use_azuread = true
}

provider "azapi" {
  subscription_id = var.subscription_id
}
