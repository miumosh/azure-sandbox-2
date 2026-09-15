# ============================================================================
# サブスクリプションレベルの診断設定 (Activity Log のエクスポート) 検証
#
# ポータルで言うところの
#   [サブスクリプション] > [アクティビティ ログ] > [診断設定] > [診断設定を追加する]
# に相当する。カテゴリのうち Administrative / Security / ServiceHealth /
# ResourceHealth を有効にして Log Analytics へ流す最小構成。
#
# ポイント:
#   - サブスクリプションスコープの診断設定は「拡張リソース」であり、
#     リソースグループには属さない。ID は
#       /subscriptions/<guid>/providers/Microsoft.Insights/diagnosticSettings/<name>
#     となる。RG を作るのは受け皿の Log Analytics ワークスペースのためだけ。
#   - Terraform では専用リソースは無く、通常の azurerm_monitor_diagnostic_setting の
#     target_resource_id にサブスクリプション ID (/subscriptions/<guid>) を渡す。
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
