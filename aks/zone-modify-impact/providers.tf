# ============================================================================
# AKS のゾーン変更 ([1,2] / null -> [1,2,3]) 検証用プロバイダ定義
# - 別環境で plan が in-place だったものと同じ判定になるかを見るため、
#   azurerm のバージョンは別環境に合わせて変えてよい (zones の扱いは 4.16.0 で変わっている)。
# ============================================================================
terraform {
  required_version = "~> 1.15.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.80.0" # 依頼は ~> 4.80.8 だが 4.80.8 は未リリース (4.80.0 の次は 4.81.0)。要確認
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
