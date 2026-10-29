# VNet フローログの保存先ストレージを Public Network Access = Disabled にできるか

VNet フローログ (Network Watcher) の保存先ストレージアカウントのネットワーク制限について調べた結果と、Terraform のサンプル。

## 結論

| 問い | 答え |
|------|------|
| Public Network Access は `Disabled` でもよいか | **よい** (ドキュメント上の根拠あり + 実機で確認済み。下記の注意点つき) |
| その代わりに AzureServices を Bypass すればよいか | **そう**。`networkRuleSet.bypass = AzureServices` (ポータルの「信頼されたサービスの一覧にある Azure サービスがこのストレージ アカウントにアクセスすることを許可します」) が必須。外すと書き込みが失敗することも実機で確認済み |
| 共有キー無効 (`allowSharedKeyAccess = false`) でもよいか | **よい** (実機で確認済み)。Network Watcher は Entra 認証 (OAuth) で書き込む |

### 根拠

1. **Network Watcher は「信頼された Azure サービス」に含まれる**
   [Trusted Azure services](https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security-trusted-azure-services) の
   "Trusted access for resources registered in your Microsoft Entra tenant" の表に
   `Azure networking services` / `Microsoft.Network` / "Store and analyze network traffic logs, including through Azure Network Watcher" とある。
   条件はストレージと同じ Entra テナントのサブスクリプションであること。
2. **信頼されたサービスの例外は `Disabled` でも有効なまま残る**
   [Guidelines & limitations: Azure Storage firewall](https://learn.microsoft.com/en-us/azure/storage/common/storage-network-security-limitations) より:
   > By design, access to a storage account from trusted services takes the highest precedence over other network access restrictions.
   > If you set **Public network access** to **Disabled** after previously setting it to **Enabled from selected virtual networks and IP addresses**,
   > any resource instances and exceptions that you previously configured, including **Allow Azure services on the trusted services list to access this storage account**, will remain in effect.
3. **Network Watcher 側の案内**
   [Network Watcher FAQ](https://learn.microsoft.com/en-us/azure/network-watcher/frequently-asked-questions) の "How do I use flow logs with a storage account behind a firewall?" では、
   `Enabled from selected virtual networks and IP addresses` + 信頼されたサービスの例外 を案内している。
   `Disabled` を明示した記述は Network Watcher 側には無く、上記 2 のストレージ側の仕様が根拠になる。
   同 FAQ には、プライベートエンドポイント付きのストレージ / サービスエンドポイントのストレージにも送信できると書かれている。

### 注意点

- **`Disabled` だけ設定して `defaultAction` を `Allow` のままにしない**。
  テンプレート / IaC で `publicNetworkAccess = Disabled` にしても `defaultAction` は自動で `Deny` にならず、
  Defender for Storage / Advisor が「ネットワーク制限なし」と警告する (実際の通信は `publicNetworkAccess` が優先されて遮断される)。
  このサンプルでは `default_action = "Deny"` を明示している。
- ドキュメントの文言は「Enabled (selected networks) から Disabled に**変更した**場合に例外が残る」という書き方だが、
  "By design ... highest precedence" とあるので、最初から `Disabled` + `bypass = AzureServices` で作った場合も同じ扱いになると読める。
  → 最初から `Disabled` で作った構成で書き込めることを実機で確認した ([検証結果](#検証結果-2026-10-29))。
- `Disabled` にすると、手元の端末からもパブリックエンドポイント経由でログ (Blob) を読めない。
  閲覧はプライベートエンドポイント経由にするか、Log Analytics (Traffic Analytics) 側で見る。
  コンテナーの有無 / 更新時刻だけならコントロールプレーン (`az rest` で ARM API) から確認できる (`terraform output verify_flow_log_written_command`)。
- **共有キー無効 (`shared_access_key_enabled = false`) で書き込めるかはドキュメントで確認できなかった**。
  FAQ に「ファイアウォールの内側のストレージにはまずキーで接続し、失敗したらトークンに切り替える (そのため 403 がログに出る)」とあるので
  Entra 認証で書ける見込みだが、明記は無い。→ 実機では追記 (PutBlock / PutBlockList) がすべて OAuth で成功した ([検証結果](#検証結果-2026-10-29))。
  ちなみに Network Watcher の**パケットキャプチャ**は SAS で書き込むため共有キーが必須 ([Secure your Azure Network Watcher deployment](https://docs.azure.cn/en-us/network-watcher/secure-network-watcher))。
- その他の保存先ストレージの要件 ([Virtual network flow logs](https://learn.microsoft.com/en-us/azure/network-watcher/vnet-flow-logs-overview)):
  VNet と同じリージョン / 同じ Entra テナント / Standard (Premium 不可) / CMK をローテーションするとフローログが止まる (無効化→再有効化が必要)。
- NSG フローログは 2025-06-30 以降新規作成できないので、VNet フローログを使う。

## 検証結果 (2026-10-29)

japaneast / azurerm v5.10.0 / 既定値 (`Disabled` + `default_action = Deny` + `bypass = AzureServices` + 共有キー無効) で apply して確認した。
データプレーンは閉じているので、書き込みの成否はストレージのメトリクス `Transactions` (ApiName / Authentication / ResponseType 別、1 分粒度) で判定した。

| 時刻 (UTC) | 操作 | 結果 |
|------------|------|------|
| 05:13 ごろ | apply (フローログ作成は 13 秒で成功) | - |
| 05:17 | `insights-logs-flowlogflowevent` コンテナーが作られる | apply から約 4 分 |
| 05:19〜05:23 | フローログの追記 `PutBlock` / `PutBlockList` | **OAuth / Success** (毎分) |
| 05:21 | `bypass = None` に変更 (`storage_bypass_azure_services = false`) | - |
| 05:23 | 追記 | まだ OAuth / Success (反映に 2 分ほどかかる) |
| 05:26〜05:30 | 追記 | **OAuth / AuthorizationError** (毎分 1〜3 回。リトライしている) |
| 05:29 | `bypass = AzureServices` に戻す | - |
| 05:31 | 追記 | **OAuth / Success** に回復 |

わかったこと:

- `publicNetworkAccess = Disabled` でも `bypass = AzureServices` があれば Network Watcher は書き込める。**最初から Disabled で作っても**よい
- bypass を外すと `AuthorizationError` で書き込めなくなる。**Disabled にするなら bypass は必須**
- Network Watcher の書き込みは **Entra 認証 (OAuth)**。共有キーを無効にしていても問題ない
- 手元の端末からの `az storage blob list --auth-mode login` は network rules で拒否された (メトリクス上は `ListBlobs / OAuth / AuthorizationError`)
- 設定変更の反映には 2 分程度のラグがある

補足:

- メトリクスには `AccountKey` 認証の成功も出る (`ListContainers` / `GetBlobServiceProperties` など) が、時刻を突き合わせると
  `az rest` での ARM 経由のコンテナー一覧 (毎分ポーリング) と `terraform apply` のリフレッシュに一致した。
  コントロールプレーン (ストレージ RP) が内部でデータプレーンを呼ぶ分で、共有キー無効の影響を受けない (= Network Watcher の書き込みではない)。
  最初の `CreateContainer` / `PutBlob` (AccountKey) の発生元は特定できていない
- bypass を外していた間 (05:24〜05:30 ごろ) のフローデータが、回復後に再送されたのか欠損したのかは確認していない (データプレーンを閉じているため Blob の中身を読めない)

## 構成

| ファイル | 内容 |
|----------|------|
| `network.tf` | フローログ対象の VNet / サブネット / NSG |
| `storage.tf` | 保存先ストレージ (`public_network_access = Disabled` / `default_action = Deny` / `bypass = AzureServices` / 共有キー無効) |
| `flowlog.tf` | 既存 Network Watcher (`NetworkWatcherRG/NetworkWatcher_<region>`) を参照して VNet フローログを作成 (保持 7 日) |
| `vm.tf` | トラフィック発生源の VM (B1s / パブリック IP なし)。`create_test_vm = false` で作らない |

ポイントになる設定 (`storage.tf`):

```hcl
resource "azurerm_storage_account" "flowlog" {
  # ...
  public_network_access = "Disabled"

  network_rules {
    default_action = "Deny"            # Defender / Advisor の警告を避けるため明示
    bypass         = ["AzureServices"] # Network Watcher (Microsoft.Network) の書き込みを通す
  }

  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
}
```

- azurerm v5 では `public_network_access_enabled` (bool) は非推奨で、`public_network_access` (文字列) を使う
- 書き込み先コンテナー `insights-logs-flowlogflowevent` は Network Watcher が自動で作るので、
  Terraform がストレージのデータプレーンを触る処理は無い (= `Disabled` のままでも apply できる)

## 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id を記入
terraform init
terraform apply

# 数分〜10 分ほど後にフローログが書き込まれたか確認
eval "$(terraform output -raw verify_storage_network_command)"
eval "$(terraform output -raw verify_flow_log_written_command)"   # insights-logs-flowlogflowevent が出れば書き込み成功

terraform destroy
```

比較検証用のスイッチ:

| 変数 | 用途 |
|------|------|
| `storage_public_network_access = "Enabled"` | FAQ どおりの selected networks 構成と比較する (`allowed_client_ips` で手元から Blob を読める) |
| `storage_bypass_azure_services = false` | bypass を外すと書き込めなくなることを確認する |

## シークレットの扱い

| 対象 | 対策 |
|------|------|
| ストレージ | 共有キー認証を無効化。provider も `storage_use_azuread = true` で Entra 認証 |
| VM | パスワード認証なし。SSH 鍵は作成に必須なので生成するが、秘密鍵はファイルにも output にも出さない (ログインもしない) |
| outputs | キー / 接続文字列 / 秘密鍵は出力しない |
| `terraform.tfvars` | subscription_id / 接続元 IP を含むので `.gitignore` 済み。テンプレートは `terraform.tfvars.sample` |
| state / plan | ストレージのアクセスキーと VM の SSH 秘密鍵が平文で入る。`*.tfstate*` / `*.tfplan` を `.gitignore` で除外 |
| ダウンロードしたフローログ | 実 IP / リソース ID を含むので `out/` / `*.json` を除外 |

`.gitignore` はこのディレクトリ単体で持っているので、ディレクトリを切り出しても漏れない。

## 費用の目安

- VNet フローログ: 収集量 (GB) 課金。サブスクリプションあたり月 5 GB まで無料。VM 1 台の検証なら無料枠内に収まる見込み
- VM Standard_B1s + Standard HDD: 1 時間あたり数円程度
- ストレージ (LRS): 数 MB なのでほぼ ¥0

検証が終わったら `terraform destroy` する。
