# ============================================================================
# 検証の主役: メンテナンス設定 (properties.maintenanceConfiguration)
#
# azurerm_managed_redis には maintenanceConfiguration に相当する属性が無い
# (azurerm v5.10.0 のスキーマで確認済み)。そのため azapi_update_resource で
# 既存クラスタのプロパティを部分的に上書きする。
#
#   - azapi_update_resource は GET -> body をマージ -> PUT する。
#     body に書いた項目だけを管理対象とし、それ以外 (sku / tags 等) は azurerm 側に任せる。
#   - destroy してもメンテナンス設定は Azure 側に残る (リソースを消さないため)。
#     解除したい場合は var.maintenance_windows = [] で apply する。
# ============================================================================
resource "azapi_update_resource" "maintenance" {
  type        = "Microsoft.Cache/redisEnterprise@${local.arm_api_version}"
  resource_id = azurerm_managed_redis.this.id

  body = {
    properties = {
      maintenanceConfiguration = {
        maintenanceWindows = local.maintenance_windows
      }
    }
  }

  # 適用後の値を output で確認できるように読み戻す
  response_export_values = ["properties.maintenanceConfiguration"]
}
