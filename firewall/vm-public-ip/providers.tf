# ============================================================================
# VM の インスタンスレベル Public IP と Azure Firewall を併用する経路検証
#
# 実現したい経路:
#   1. 外部 -> VM の Public IP へのインバウンド。戻りも同じ Public IP から返す。
#   2. VM -> 宛先A / 宛先B は Public IP から直接インターネットへ出る。
#   3. それ以外のアウトバウンド (OS Update 等) は Azure Firewall 経由。
#
# 肝は「サブネットのルートテーブル」だけで 1〜3 を作り分ける点。
# ルートは宛先 (destination) でしか分岐できないため、戻りパケットも
# 「クライアントの Public IP 宛のルート」として表現する必要がある。
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
