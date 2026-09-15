terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# ===========================================================================
# Resource Provider (RP) 自動登録について
# ===========================================================================
# azurerm v4 では、真偽値の `skip_provider_registration` が廃止され、
# 5 モードを取る `resource_provider_registrations` に置き換わった。
#   none / core / extended / all / legacy
#   - v4.x のデフォルト: "legacy" (v3 互換セット)
#   - v5.0 以降のデフォルト: "none" (何も自動登録しない) に変更予定
#
# 【重要 / 公式ドキュメントに明記が「ない」点】
#   公式ドキュメント (Registry の provider index / 4.0 upgrade guide) は
#   各モードの意味は説明するが、"各セットにどの RP が含まれるか" の一覧は載せていない。
#   実際に含まれる RP はプロバイダのソースコードが唯一の一次情報。
#   → ソース (required.go) で確認した結果、Microsoft.CertificateRegistration は
#     legacy(59個)・core・extended・all の "いずれのセットにも含まれない"。
#     つまり v4 デフォルト(legacy)でも v5 デフォルト(none)でも自動登録されない。
#
# 【一次情報リンク】
#   - RP 登録セットの実体 (Legacy()=59個 / Core / Extended / All を定義。凍結済みで将来削除予定):
#       https://github.com/hashicorp/terraform-provider-azurerm/blob/main/internal/resourceproviders/required.go
#   - v4.0 アップグレードガイド (skip_provider_registration → resource_provider_registrations):
#       https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/4.0-upgrade-guide
#   - provider index ドキュメント (引数仕様・デフォルト値。v5.0 で default=none に):
#       https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs
#
# 【この構成での対応】
#   cert_source = "app_service_order" のとき Microsoft.CertificateRegistration が必須だが
#   上記のとおり自動登録されないため、resource_providers_to_register で明示登録する。
#   (self_signed モードでは不要だが、登録は冪等かつ無害なので常時指定でよい)
# ===========================================================================
provider "azurerm" {
  features {}

  subscription_id                = var.subscription_id
  resource_providers_to_register = ["Microsoft.CertificateRegistration"]
}
