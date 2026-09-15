# ============================================================================
# サブスクリプションレベルの診断設定 (Activity Log エクスポート)
# ============================================================================

# provider の subscription_id で認証しているサブスクリプション自身を参照する。
# .id は "/subscriptions/<guid>" という形で、これがそのまま診断設定の
# target_resource_id になる。RG やリソースの ID ではない点が肝。
data "azurerm_subscription" "current" {}

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name               = local.diagnostic_setting_name
  target_resource_id = data.azurerm_subscription.current.id

  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  # --------------------------------------------------------------------------
  # 有効化するカテゴリ。
  #
  # 注意 1: azurerm 4.x では enabled_log ブロックに書いたカテゴリだけが有効になる。
  #         3.x にあった `log` ブロックと retention_policy は廃止済みで、
  #         保持期間は宛先 (LAW / Storage) 側の設定に一本化されている。
  #
  # 注意 2: category と category_group は別の名前空間。取り違えると 400 になる。
  #           category       : Administrative / Security / ServiceHealth /
  #                            ResourceHealth / Alert / Recommendation /
  #                            Policy / Autoscale
  #           category_group : サブスクリプションスコープでは "allLogs" のみ
  #                            (リソーススコープで使える "audit" も通らない)
  #         category_group にカテゴリ名を渡すと:
  #           BadRequest: CategoryGroup: 'ResourceHealth' is not supported,
  #                       supported ones are: 'allLogs'
  #         しかも API は配列の先頭にある不正な値しか報告しないため、
  #         全カテゴリが同じ間違いでも 1 つだけ名指しされてミスリードになる。
  #
  # 注意 3: サブスクリプションスコープにメトリックカテゴリは存在しないため
  #         enabled_metric / metric ブロックは書かない。provider 側が computed
  #         として扱うので plan には "(known after apply)" と出るが、実体は空。
  #
  # 注意 4: log_analytics_destination_type は設定しない。
  #         Activity Log は宛先テーブルが AzureActivity で固定されており、
  #         "Dedicated" を指定すると API に拒否される。
  # --------------------------------------------------------------------------
  dynamic "enabled_log" {
    for_each = toset(var.activity_log_categories)

    content {
      category = enabled_log.value
    }
  }

  # LAW が消える前に診断設定を消したいので依存を明示する
  # (暗黙依存もあるが、宛先変更時の作り直し順序を安定させる目的)
  depends_on = [azurerm_log_analytics_workspace.this]
}
