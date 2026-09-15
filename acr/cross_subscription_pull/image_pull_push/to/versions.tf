terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }
}

# 既定 provider = サブスクリプション B (取り込み先 ACR / Runner VM を持つ)
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

# alias provider = サブスクリプション A (ソース側)
# 循環依存を避けるため、A 側に作る「ピアリングの片側 / AcrPull ロール / DNS VNet リンク」を
# この alias 経由で to 側から作成する。実行主体は A 側にも書き込み権限が必要。
provider "azurerm" {
  alias = "src"
  features {}
  subscription_id = var.source_subscription_id
}
