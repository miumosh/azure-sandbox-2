# ============================================================================
# VNet フローログ + ストレージのネットワーク制限 検証用プロバイダ定義
#
# - azurerm : VNet / ストレージ / フローログ一式
# - random  : リソース名のサフィックス
# - tls     : 検証用 VM の SSH 公開鍵 (ログインはしないが Linux VM の作成に必須)
# ============================================================================
terraform {
  required_version = "~> 1.15.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1.0"
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

  # ストレージアカウントは共有キー認証を無効化するため、データプレーン操作を
  # Entra ID 認証で行わせる
  storage_use_azuread = true
}
