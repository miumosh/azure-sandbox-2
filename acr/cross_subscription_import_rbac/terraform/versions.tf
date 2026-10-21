terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# ソース側 = サブスクリプション A
provider "azurerm" {
  alias = "src"
  features {}
  subscription_id = var.src_subscription_id
}

# 取り込み先側 = サブスクリプション B
provider "azurerm" {
  alias = "dst"
  features {}
  subscription_id = var.dst_subscription_id
}
