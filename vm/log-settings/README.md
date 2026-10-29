# Ubuntu VM のログを Azure Monitor Agent で Log Analytics に送る (Terraform)

Azure Linux VM (Ubuntu 24.04) に Azure Monitor Agent (AMA) を入れ、Syslog とアプリログ (テキストファイル) を
Log Analytics ワークスペースへ送り、ログ検索アラートでメール通知するまでを Terraform だけで作るサンプル。

## 構成

```
VM (Ubuntu 24.04, システム割り当てマネージド ID)
 ├─ rsyslog ──(転送)──┐
 ├─ /var/log/sampleapp/app.log   ← 1 分ごとに INFO を追記する systemd タイマー (cloud-init)
 └─ AMA 拡張機能 (AzureMonitorLinuxAgent)
        │  DCR 関連付けで収集設定を受け取る
        ▼
DCR ─┬─ syslog   : Microsoft-Syslog         → Syslog テーブル (組み込み)
     └─ log_file : Custom-SampleApp_CL (変換で Level/Message を抽出) → SampleApp_CL テーブル (カスタム)
        ▼
Log Analytics ワークスペース
        ▼
ログ検索アラート (ERROR / err 以上) → アクショングループ (メール)
```

| ファイル | 内容 |
|----------|------|
| `vm.tf` | VM (パブリック IP なし) と AMA 拡張機能 |
| `templates/cloud-init.yaml.tftpl` | サンプルアプリ (ログを書くだけの systemd タイマー) と logrotate |
| `log_analytics.tf` | ワークスペースとカスタムテーブル `SampleApp_CL` |
| `dcr.tf` | DCR (Syslog + テキストログ) と VM への関連付け |
| `alert.tf` | アクショングループとログ検索アラート 2 本 |

## ポイント

### Custom Table はアプリログには必須か

**必須**。AMA のテキストログ (`log_file` データソース) の送信先になる組み込みテーブルは無く、
`_CL` で終わるカスタムテーブルを **DCR より先に** 作っておく必要がある (DCR 作成時に出力先テーブルの存在が検証される)。
`dcr.tf` では `depends_on` で順序を保証している。

- azurerm v4 までは新規のカスタムテーブルを作るのに azapi が必要だったが、azurerm v5 では
  `azurerm_log_analytics_workspace_table_custom_log` で作れるので azurerm だけで完結する
- テーブルには AMA が送る列 `TimeGenerated` / `RawData` / `Computer` / `FilePath` に加え、
  DCR の変換 (`transform_kql`) で追加する列 (`Level` / `Message`) も定義しておく
- Syslog は組み込みの `Syslog` テーブルに入るのでテーブル作成は不要

ログの形式 (CSV / 複数行 / JSON など) によって DCR とテーブル定義がどう変わるかは [app-log-formats.md](app-log-formats.md) にまとめた。

### /var/log/messages と syslog

- `/var/log/messages` は RHEL 系の rsyslog 既定の出力先で、Ubuntu には無い (Ubuntu は `/var/log/syslog`)
- AMA の Syslog 収集は **ファイルを読むのではなく**、rsyslog から AMA へ転送させる方式。
  DCR を関連付けると AMA が `/etc/rsyslog.d/` に転送設定を置き、DCR で指定したファシリティ / 重要度だけが送られる
- そのため Ubuntu / RHEL どちらでも DCR の書き方は同じ (`syslog` データソース)

### その他

- **DCE は不要**。テキストログ収集でも、Private Link (AMPLS) を使わない限りデータ収集エンドポイントは要らない
- AMA は VM のマネージド ID で認証する。ここではシステム割り当て ID を有効にしている
- AMA は `*.handler.control.monitor.azure.com` / `*.ods.opinsights.azure.com` へ HTTPS で外向き通信が必要。
  サンドボックスなのでサブネットのデフォルトアウトバウンドを有効にしている (本番は NAT Gateway / Firewall / AMPLS)
- テキストログの `TimeGenerated` は既定では AMA が読み取った時刻になる。ここでは変換で行頭のタイムスタンプに置き換えている
- AMA は `syslog` ユーザーで動くので、ログファイル / ディレクトリは読める権限にしておく

### アラートの注意点 (実機で引っかかった点)

- **Syslog の `SeverityLevel` は AMA だと `error` / `critical`** (旧 Log Analytics エージェントの `err` / `crit` ではない)。
  `where SeverityLevel == "err"` のような古いクエリは一致せず、アラートが発報しない
- **ログ検索アラートの評価ウィンドウは `TimeGenerated` 基準**。取り込み遅延 (実機で最大 8 分) があると、
  ウィンドウを過ぎてから取り込まれたレコードは数えられない。テキストログで `TimeGenerated` をログ行の時刻に置き換えると特に起きやすい。
  `alert.tf` では `query_time_range_override = "PT1H"` で検索範囲を広げ、クエリ内で `ingestion_time() > ago(5m)` で絞っている
- AMA 自身 (MetricsExtension / agentlauncher / python3) のログが daemon.info で大量に入る (起動直後 10 分で 400 件超)。
  コストが気になる場合は収集ファシリティ / レベルを絞るか、DCR の変換で落とす

## 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id / alert_email_addresses を記入
terraform init
terraform apply
```

`alert_email_addresses` は個人のアドレスになるので `terraform.tfvars` (git 管理外) にだけ書く。
アクショングループを作るとそのアドレスに「アクショングループに追加された」通知メールが届く。

### 確認

```bash
# AMA が動いているか / rsyslog の転送設定 / アプリログの末尾
eval "$(terraform output -raw verify_ama_command)"

# Syslog (user.err) とアプリログ (ERROR) を 1 行ずつ書き込む -> 両方のアラートが発報する
eval "$(terraform output -raw generate_error_logs_command)"

# 取り込まれたログを確認 (反映まで 5〜10 分程度)
eval "$(terraform output -raw query_logs_command)"
```

### 後片付け

```bash
terraform destroy
```

## 検証結果 (2026-10-29)

japaneast / azurerm v5.10.0 / Terraform 1.15.5 で apply して確認した。

| 時刻 (UTC) | 操作 / 事象 | 結果 |
|------------|-------------|------|
| 08:39〜08:41 | apply (17 リソース、約 2 分) | AMA 拡張機能は 52 秒で完了。アクショングループ追加の通知メールが届く |
| 08:41 | AMA が DCR を取得し `/etc/rsyslog.d/10-azuremonitoragent-omfwd.conf` を配置 | rsyslog は `*.*` を TCP で AMA に転送 (絞り込みは AMA 側で DCR に従って行う) |
| 08:42 | `logger -p user.err` とアプリログ ERROR を書き込み | - |
| 08:43〜08:45 | Syslog の最初の取り込み | apply から約 4 分 |
| 08:50 | SampleApp_CL の最初の取り込み (08:42〜08:45 の行がまとめて入る) | 最初のバッチのみ約 8 分遅延。以降は 1〜2 分 |
| 〜08:52 | アラート 2 本とも未発報 | Syslog は `err` 表記の不一致、アプリログは遅延でウィンドウ外 → クエリを修正して apply |
| 08:53 | err / crit / warning とアプリログ ERROR を再投入 | 1.5〜2 分で取り込み。`SeverityLevel` は `error` / `critical` / `warning` |
| 08:58 / 09:00 | アプリログ / Syslog アラートが発報 (Fired) | メール通知 |

わかったこと:

- Terraform (azurerm のみ) で VM / AMA / LAW / カスタムテーブル / DCR / 関連付け / アラートまで一括で作れる。DCE は不要
- アプリログはカスタムテーブル + DCR の `log_file` で取り込め、DCR の変換で `Level` / `Message` の抽出と `TimeGenerated` の置き換えができた
- AMA はファイル末尾から読み始めるため、**DCR が届く前に書かれた行 (08:41:00 の 1 行目) は取り込まれなかった**
- Syslog の重要度の表記とアラートの評価ウィンドウ (取り込み遅延) は上記「アラートの注意点」のとおり
