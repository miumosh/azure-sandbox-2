# ============================================================================
# 検証の主役 1: サブスクリプション単位の Defender プラン (Microsoft.Security/pricings)
#
# ポータルの [Defender for Cloud] > [環境設定] > [<サブスクリプション>] > [Defender プラン]
# のトグルに相当する。
#
#   - tier = "Standard" で有効、destroy すると Free に戻る (リソース自体は消えない)
#   - サブスクリプション内の該当リソースすべてが課金対象になる点に注意
#     (このサブスクリプションには既存のストレージアカウントがあるため、Storage は既定で作らない)
#   - extension ブロックに書いた拡張だけが有効になる
# ============================================================================
resource "azurerm_security_center_subscription_pricing" "this" {
  for_each = { for k, v in local.subscription_plans : k => v if v.enabled }

  resource_type = each.key
  tier          = "Standard"
  subplan       = each.value.subplan

  dynamic "extension" {
    for_each = each.value.extensions

    content {
      name                            = extension.key
      additional_extension_properties = extension.value
    }
  }
}
