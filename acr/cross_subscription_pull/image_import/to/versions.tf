terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }
}

# Pull する側 = サブスクリプション B (import 先 private ACR と実行用 Identity を持つ)
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
