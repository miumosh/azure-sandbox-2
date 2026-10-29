# ============================================================================
# Linux VM (Ubuntu) + Azure Monitor Agent によるログ収集 検証用プロバイダ定義
#
# - azurerm : VM / Log Analytics / カスタムテーブル / DCR / アラート一式
# - random  : リソース名のサフィックス
# - tls     : VM の SSH 公開鍵 (ログインはしないが Linux VM の作成に必須)
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
    log_analytics_workspace {
      # destroy 後に同名で作り直せるよう、論理削除 (14 日保持) せず完全に削除する
      permanently_delete_on_destroy = true
    }
  }

  subscription_id = var.subscription_id
}
