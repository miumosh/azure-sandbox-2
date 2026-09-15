# サブスクリプションレベルの診断設定 (Activity Log エクスポート) を Terraform で構成する

ポータルの
**[サブスクリプション] > [アクティビティ ログ] > [診断設定] > [診断設定を追加する]**
に相当する構成を IaC 化した最小サンプル。

有効化するカテゴリは既定で **Administrative / Security / ServiceHealth / ResourceHealth** の 4 つ。

## 構成

```
[ Subscription ]
      │  Activity Log (Administrative / Security / ServiceHealth / ResourceHealth)
      │
      ▼
azurerm_monitor_diagnostic_setting          ← サブスクリプションスコープの拡張リソース
  target_resource_id = /subscriptions/<guid>   (RG には属さない)
      │
      ▼
[ rg-subdiag-xxxxxx ]
   └─ Log Analytics Workspace  →  AzureActivity テーブル
```

| ファイル | 役割 |
|----------|------|
| `providers.tf` | Terraform / azurerm のバージョン固定 |
| `variables.tf` | 環境依存値とカテゴリの指定 (指定可能な全カテゴリの説明もここ) |
| `locals.tf` | 命名 / タグ / ワークスペース設定 |
| `rg.tf` | Log Analytics を置くための RG |
| `log_analytics.tf` | 宛先ワークスペース (保持日数・日次取り込み上限) |
| `diagnostic_setting.tf` | **本題**。サブスクリプションスコープの診断設定 |
| `outputs.tf` | 確認用の az コマンドを出力 |

## 実装上のポイント

### 1. 専用リソースは無い。`target_resource_id` にサブスクリプション ID を渡す

Terraform に「サブスクリプション診断設定」用の専用リソースは無く、通常の
`azurerm_monitor_diagnostic_setting` をそのまま使う。渡す ID が
`/subscriptions/<guid>` になるだけ。

```hcl
data "azurerm_subscription" "current" {}

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "diag-activitylog-xxxxxx"
  target_resource_id         = data.azurerm_subscription.current.id  # /subscriptions/<guid>
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  ...
}
```

**ARM 上の ID と Terraform state の ID は形式が違う**（実測）。

| | 形式 |
|---|---|
| ARM (az が返す `id`) | `/subscriptions/<guid>/providers/microsoft.insights/diagnosticSettings/<name>` |
| Terraform state の `id` | `/subscriptions/<guid>` + `\|` + `<name>` |

そのため `terraform import` には **`|` 区切り**を渡す必要がある。ARM の ID を渡すと:

```
Error: expected the Monitor Diagnostics ID to be in the format `{resourceId}|{name}` but got 1 segments
```

**リソースグループには属さない**ので、RG を消しても診断設定は残る（逆に
`terraform destroy` では正しく消える）。

- 名前はサブスクリプション内で一意
- 1 サブスクリプションあたり **最大 5 件**
- 同じ宛先 (data sink) を、同じカテゴリで複数の診断設定から使い回せない（後述）

### 2. カテゴリは動的取得できないのでハードコードする

`azurerm_monitor_diagnostic_categories` データソースにサブスクリプション ID を
渡すと、plan の時点で失敗する（実測）。

```hcl
data "azurerm_monitor_diagnostic_categories" "sub" {
  resource_id = data.azurerm_subscription.current.id  # NG
}
```
```
Error: retrieving Diagnostics Categories for Resource "Scope (Scope: \"/subscriptions/<guid>\")":
unexpected status 400 (400 Bad Request) with response:
{"code":"ResourceTypeNotSupported","message":"The resource type '/' does not support diagnostic settings."}
```

裏側の `microsoft.insights/diagnosticSettingsCategories` API も同じ 400 を返すため、
そもそもサブスクリプションスコープではカテゴリ一覧を引けない。列挙するしかない。
指定できるのは次の 8 種類:

| カテゴリ | 内容 |
|----------|------|
| `Administrative` | ARM への書き込み操作 (作成 / 更新 / 削除)、ロール割り当てなど |
| `Security` | Microsoft Defender for Cloud のアラート / 推奨 |
| `ServiceHealth` | Azure 側の障害・計画メンテナンス・ヘルスアドバイザリ |
| `ResourceHealth` | 個々のリソースの正常性遷移 (Available / Unavailable / Degraded) |
| `Alert` | 従来型アラートの発報 |
| `Recommendation` | Azure Advisor の推奨 |
| `Policy` | Azure Policy の評価結果 (audit / deny) |
| `Autoscale` | 自動スケールの実行イベント |

本サンプルでは `var.activity_log_categories` を `dynamic "enabled_log"` で展開している。
カテゴリを増減して差分を見たい場合は `terraform.tfvars` で上書きする。

**この 8 個は `category` に書く値であって、`category_group` に書く値ではない。**
`category_group` に指定できるのはサブスクリプションスコープでは `allLogs` だけで、
カテゴリ名を渡すと 400 になる（→ 「ハマりどころ」節）。

```hcl
enabled_log { category       = "ResourceHealth" }  # OK
enabled_log { category_group = "allLogs"        }  # OK (8 カテゴリすべてに展開される)
enabled_log { category_group = "ResourceHealth" }  # NG: 400 BadRequest
```

`allLogs` でも要件は満たせるが、「どのカテゴリを有効にしたか」がコード上に残らないので、
本サンプルでは個別カテゴリを明示している。

### 3. azurerm 4.x での書き方の差分

| 3.x まで | 4.x |
|----------|-----|
| `log { category = "..." , enabled = true }` | `enabled_log { category = "..." }` （書いたものだけが有効） |
| `retention_policy { ... }` | **廃止**。保持期間は宛先 (LAW / Storage) 側の設定に一本化 |
| `metric { ... }` | `enabled_metric { ... }`（サブスクリプションスコープでは不要） |

### 4. 書いてはいけないもの

- **`enabled_metric` / `metric`** — サブスクリプションスコープにメトリックカテゴリは存在しない。
  plan では provider の computed 属性として `(known after apply)` と出るが実体は空。
- **`log_analytics_destination_type`** — Activity Log の格納先は `AzureActivity` テーブルで
  固定されているため指定しない。
- **`category_group` にカテゴリ名** — `category` との取り違え。今回踏んだ罠なので
  「ハマりどころ」節を参照。

## 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars
# subscription_id を埋める (az account show --query id -o tsv)

terraform init
terraform plan
terraform apply
```

## 確認方法

### 診断設定が入ったか

`az monitor diagnostic-settings subscription list` のレスポンスは `logs` /
`workspaceId` が **`properties` 配下ではなくトップレベル**に来る点に注意する。

```bash
az monitor diagnostic-settings subscription list -o json \
  --query "value[].{name:name, categories:logs[?enabled].category}"

# または outputs のコマンドをそのまま
eval "$(terraform output -raw verify_setting_command)"
```

期待値:

```json
[
  {
    "name": "diag-activitylog-xxxxxx",
    "categories": ["Security", "Administrative", "ResourceHealth", "ServiceHealth"]
  }
]
```

無効なカテゴリも `enabled: false` として全 8 件がレスポンスに含まれる。

### ログが流れてきたか

```bash
terraform output -raw verify_logs_command
```

```kusto
AzureActivity
| where TimeGenerated > ago(1h)
| summarize count() by Category
```

**カテゴリごとに出現条件が違う点に注意する。**

| カテゴリ | いつ出るか |
|----------|-----------|
| `Administrative` | 何かリソースを作れば即座に出る。`terraform apply` 自体が記録されるので確認しやすい |
| `Security` | Defender for Cloud が有効でアラートが発生したときのみ |
| `ServiceHealth` | Azure 側が障害 / メンテナンス通知を出したときのみ。**通常は空のまま** |
| `ResourceHealth` | リソースの正常性が遷移したときのみ。**通常は空のまま** |

つまり `ServiceHealth` / `ResourceHealth` は「設定が入っていること」までしか
即座には確認できない。手早く動作確認したいなら `Administrative` を見る
（適当なタグを付け外しすれば `Microsoft.Resources/tags/write` が記録される）。

初回のログ到達には診断設定の作成から **数分〜十数分** かかる。

```bash
# Administrative を強制的に発生させる例
az group update -n rg-subdiag-xxxxxx --set tags.probe=1
```

## 検証結果 (2026-09-10 / japaneast / azurerm 4.76.0)

実機 apply で **4 カテゴリすべて成功**した。`ResourceHealth` も問題なく有効化できる。

| 項目 | 値 |
|------|-----|
| サブスクリプション | `<SUBSCRIPTION_ID>` (従量課金) |
| リソースグループ | `rg-subdiag-di8514` |
| ワークスペース | `law-subdiag-di8514` |
| 診断設定名 | `diag-activitylog-di8514` |
| Terraform state ID | `/subscriptions/<guid>|diag-activitylog-di8514` |
| ARM ID | `/subscriptions/<guid>/providers/microsoft.insights/diagnosticSettings/diag-activitylog-di8514` |

```
$ az monitor diagnostic-settings subscription show -n diag-activitylog-di8514 --query 'logs[?enabled].category' -o tsv
Security
Administrative
ResourceHealth
ServiceHealth
```

### ハマりどころ: `category` と `category_group` の取り違え

実際に踏んだエラーはこれ:

```
Error: creating Monitor Diagnostics Setting "xxx" for Resource "/subscriptions/xxx":
unexpected status 400 (400 Bad Request) with response:
{"code":"BadRequest","message":"CategoryGroup: 'ResourceHealth' is not supported, supported ones are: 'allLogs'"}
```

原因は **`enabled_log` に `category` ではなく `category_group` を書いていた**こと。
スコープもリソース ID もカテゴリ名も正しい。

```hcl
# NG
dynamic "enabled_log" {
  for_each = toset(["Administrative", "Security", "ServiceHealth", "ResourceHealth"])
  content {
    category_group = enabled_log.value   # ← ここ
  }
}

# OK
dynamic "enabled_log" {
  for_each = toset(["Administrative", "Security", "ServiceHealth", "ResourceHealth"])
  content {
    category = enabled_log.value
  }
}
```

`category` と `category_group` は**別の名前空間**である。

| 属性 | 指定できる値 (サブスクリプションスコープ) |
|------|------------------------------------------|
| `category` | `Administrative` / `Security` / `ServiceHealth` / `ResourceHealth` / `Alert` / `Recommendation` / `Policy` / `Autoscale` |
| `category_group` | **`allLogs` のみ**。リソーススコープで使える `audit` すら通らない |

```
$ # categoryGroup に audit を渡した場合 (サブスクリプションスコープ)
BadRequest: CategoryGroup: 'audit' is not supported, supported ones are: 'allLogs'
```

#### エラーメッセージが ResourceHealth を名指しするのはミスリード

4 カテゴリすべてを `category_group` で送っているのに、メッセージには 1 つしか出ない。
API は**配列の先頭にある不正な `categoryGroup` だけを報告する**ため、
「ResourceHealth だけが未対応なのか？」と誤読しやすい。実際は 4 つとも同じエラーになる。

```
$ # 単体で送るとどれも同じ
Administrative -> CategoryGroup: 'Administrative' is not supported, supported ones are: 'allLogs'
Security       -> CategoryGroup: 'Security' is not supported, supported ones are: 'allLogs'
ServiceHealth  -> CategoryGroup: 'ServiceHealth' is not supported, supported ones are: 'allLogs'
```

Terraform 経由だと `toset()` の反復順が JSON の配列順になるため、
アルファベット順とは限らない位置のカテゴリが名指しされる（今回は `ResourceHealth`）。

### そのほか切り分けで試したパターン

スコープやカテゴリ名を間違えた場合は、上記とは**別のエラーコード**になる。
エラーメッセージから原因を逆引きできる。

| 試したこと | 返ってきたエラー |
|------------|------------------|
| サブスクスコープ + `category = "ResourceHealth"` | ✅ 成功 |
| `category_group = "ResourceHealth"` | `400 BadRequest: CategoryGroup: '...' is not supported, supported ones are: 'allLogs'` ← **今回の原因** |
| カテゴリ名の大小文字ミス (`Resourcehealth`) | **大小文字は区別されない**。正しいカテゴリとして解決される |
| 存在しないカテゴリ名 (`ResourcesHealth`) | `400 BadRequest: Category 'ResourcesHealth' is not supported.` |
| リソーススコープ (LAW) に `ResourceHealth` | `400 BadRequest: Category 'ResourceHealth' is not supported.` |
| リソースグループスコープ | `400 ResourceTypeNotSupported: The resource type '/' does not support diagnostic settings.` |
| 存在しないサブスクリプション ID | `Subscription '...' not found. Check the spelling and casing and try again.` |
| `terraform import` に ARM の ID を渡す | `expected the Monitor Diagnostics ID to be in the format {resourceId}\|{name} but got 1 segments` |
| 同じ LAW を同カテゴリで 2 つ目の診断設定に指定 | `409 Conflict: Data sink '<ws>' is already used in diagnostic setting '<name>' for category '<cat>'.` |

## 後片付け

```bash
terraform destroy
```

診断設定 → ワークスペース → RG の順で消える（所要 2〜3 分）。

ただし **Log Analytics ワークスペースは論理削除 (soft delete) として 14 日間残る**。

```bash
az monitor log-analytics workspace list-deleted-workspaces --query "[].name" -o tsv
# law-subdiag-xxxxxx   ← destroy 後も残る
```

課金は発生せず 14 日で自動的に消えるので通常は放置でよい。ワークスペース名は
`random_string` のサフィックス付きなので、再 apply しても論理削除済みの
ワークスペースと名前が衝突して復元されてしまう事故は起きない。

## コスト

- Log Analytics の取り込み従量課金のみ。Activity Log 自体のエクスポートは無料。
- 保持 30 日までは追加課金なし (`log_analytics_retention_in_days`)。
- 事故防止に日次取り込み上限を既定 1 GB にしている (`log_analytics_daily_quota_gb`、`-1` で無制限)。
