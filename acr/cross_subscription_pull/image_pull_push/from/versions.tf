terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }
}

# Pull される側 = サブスクリプション A (イメージのソースとなる ACR を持つ)
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
