# ============================================================================
# 同名 Private DNS ゾーンのマルチ RG 検証 用プロバイダ定義
# - 単一サブスクリプション内に RG を 3 つ作り、同名の Private DNS ゾーンを
#   RG1 / RG2 の 2 箇所に作成して名前解決の挙動を確認する。
# ============================================================================
terraform {
  required_version = "~> 1.15.5"

  required_providers {
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
      version = "~> 4.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
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
