# ============================================================================
# リソースグループ / 実行ユーザー情報
#
# Defender プラン (pricings) はサブスクリプションスコープなので RG には入らない。
# この RG は検証対象リソースを置くためだけのもの。
# ============================================================================
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
}
