# Defender for Cloud を IaC 化する際の注意点・検討項目

[README.md](README.md) のサンプルを作る過程で分かった注意点と、本番相当で使う前に決めておきたい検討項目をまとめる。

確度の表記:

- **確認済み**: スキーマ / API 仕様 / 価格 API / 対象サブスクリプションの実値で確かめたもの (2026-10-28 時点)
- **ドキュメント**: Microsoft Learn の記載によるもの (実機では未確認)
- **要確認**: 推測を含む。apply 後の実機検証で確かめる

---

## 1. 共通: Defender プランの仕組み

### 1.1 プランは「サブスクリプション単位の pricings」が基本

| 項目 | 内容 | 確度 |
|------|------|------|
| API | `Microsoft.Security/pricings/{name}` (サブスクリプションスコープ)。対象サブスクリプションでは `2024-01-01` / `2025-10-01-preview` / `2026-07-01` が使える | 確認済み |
| Tier | `Free` / `Standard` の 2 値。`Standard` で有効、`Free` で無効 | 確認済み |
| 存在 | pricings は**常に存在するシングルトン** (未設定でも `Free` で返る)。「作る / 消す」ではなく「Standard に切り替える / Free に戻す」操作 | 確認済み |
| Terraform | `azurerm_security_center_subscription_pricing` (`resource_type` / `tier` / `subplan` / `extension`) | 確認済み (azurerm 5.10.0 スキーマ) |
| destroy | Free に戻す。**同じサブスクリプションでこのプランに頼っている他のリソースも保護が外れる** | ドキュメント |

### 1.2 ポータルの「Databases」は 4 プランの束

ポータルの [Defender プラン] にある「データベース」トグルは、API 上は別々の pricings の束になっている。

| ポータル表示 | pricings の name |
|--------------|------------------|
| Azure SQL Database | `SqlServers` |
| SQL Server on machines | `SqlServerVirtualMachines` |
| オープンソースのリレーショナル データベース (PostgreSQL / MySQL / MariaDB) | `OpenSourceRelationalDatabases` |
| Azure Cosmos DB | `CosmosDbs` |

- IaC では必要なものだけを個別に Standard にできる。ポータルで「データベース」をまとめてオンにすると 4 つとも課金対象になるので、**ポータル操作と IaC が混ざると想定外の課金**につながる
- PostgreSQL を有効にすると、同じプランで **MySQL / MariaDB も保護対象**になる (サブスクリプション単位の場合)

### 1.3 サブスクリプション単位とリソース単位

| プラン | リソース単位の有効化 | 優先順位 | 確度 |
|--------|----------------------|----------|------|
| Storage | 可 (`defenderForStorageSettings/current`) | `overrideSubscriptionLevelSettings = true` のときリソース側が優先 | 確認済み (スキーマ) / ドキュメント |
| Containers | **不可** (サブスクリプション単位のみ。pricings のリソース単位は Servers だけ) | — | ドキュメント |
| PostgreSQL | 可 (`flexibleServers/advancedThreatProtectionSettings/Default`) | サブスクリプション単位が Standard のとき、リソース側を Disabled にできるかは不明 | 要確認 |
| Cosmos DB | 可 (`Microsoft.Security/advancedThreatProtectionSettings/current`) | 同上 | 要確認 |

**このサブスクリプションには既存のストレージアカウントが 2 つある** (確認済み)。サブスクリプション単位で Storage を有効にすると 2 つとも課金されるため、サンプルの既定はリソース単位にしてある。

### 1.4 無料試用 (30 日)

- 対象サブスクリプションでは 4 プランとも `freeTrialRemainingTime = 30 days` (未使用) だった (確認済み)
- 価格 API に ¥0 の `Trial` メーターがある (確認済み)。ただし次の点は要確認:
  - リソース単位の有効化で試用期間が始まるか
  - 一度 Standard → Free → Standard と切り替えたとき、試用期間が残るか (試用はプラン・サブスクリプションごとに 1 回の想定)
- **検証で試用を消費すると、後で本格利用するときには試用が残らない**。検証用と本番用でサブスクリプションを分けるかを決めておく

### 1.5 拡張 (extension) の扱い

- `extension` ブロックに書いたものが有効になる。**書かなかった拡張が明示的に無効化されるのか、既存の値が残るのか**は要確認 (ポータルで後から拡張を足した場合のドリフトに関わる)
- 拡張名は文字列の自由入力で、provider は値を検証しない。typo は apply 時の API エラーで初めて分かる (要確認)

---

## 2. Defender for Storage

| 設定 | サンプルの値 | 注意点 | 確度 |
|------|-------------|--------|------|
| subplan | `DefenderForStorageV2` | 旧プラン (トランザクション課金のクラシック) は新規利用不可の想定。subplan は必ず指定する | ドキュメント |
| 課金 | アカウント単位 ¥2.1112/時 + 一定量を超えたトランザクション ¥23.51/100 万件 | アクセスが非常に多いアカウントは超過課金が出る | 確認済み (価格 API) |
| マルウェアスキャン | `OnUploadMalwareScanning` / 上限 1 GB/月 | **GB 従量課金 (¥23.63/GB)**。上限 `-1` は無制限なので本番では必ず上限を決める。上限に達するとそれ以降はスキャンされない | 確認済み (価格) / ドキュメント |
| 機密データ検出 | `SensitiveDataDiscovery` 有効 | 追加料金なし。脅威検出の重大度判定に使う。Defender CSPM 側の機能との関係は要確認 | ドキュメント |
| スキャン結果の通知 | 未設定 | `scan_results_event_grid_topic_id` に Event Grid カスタムトピックを指定すると、結果を自動処理 (隔離など) できる | 確認済み (スキーマ) |

その他の注意点:

- **Terraform リソースを取り違えない**: `azurerm_advanced_threat_protection` もストレージアカウントを対象にできるが、これは旧来の ATP 設定。Storage には `azurerm_security_center_storage_defender` を使う (両方を書くと設定が競合しうる、要確認)
- マルウェアスキャンを有効にすると、Defender が **Event Grid のシステムトピック / サブスクリプションを自動作成する**。Terraform 管理外なので、destroy 後に残らないかを確認する (要確認)
- サンプルでは共有キー認証を無効にしている。**この状態でマルウェアスキャン・BLOB インデックスタグの書き込みが動くか**は要確認 (スキャナーは Defender 側のマネージド ID で動く想定)
- ストレージのファイアウォール / プライベートエンドポイントでネットワークを絞ったときにスキャンが動くかも本番構成では要確認
- 有効化には、ロール割り当てと Event Grid サブスクリプションを作れる権限 (Owner 相当) が要る可能性がある。Terraform 実行 ID の権限設計に関わる (要確認)

---

## 3. Defender for Containers

| 設定 | サンプルの値 | 注意点 | 確度 |
|------|-------------|--------|------|
| 有効化の単位 | サブスクリプション | リソース単位は不可。**サブスクリプション内のすべての AKS (と接続済みの Arc / EKS / GKE) が課金対象** | ドキュメント |
| 課金 | ¥1.4825 / vCore・時 | **ノードの vCore 数**で課金。オートスケールで費用も増える | 確認済み (価格 API) |
| 拡張 | `ContainerRegistriesVulnerabilityAssessments` / `AgentlessDiscoveryForKubernetes` / `ContainerSensor` | 他の拡張 (`ContainerIntegrityContribution` 等) は入れていない。必要な機能と拡張名の対応は要確認 | ドキュメント |
| センサー | AKS の `microsoft_defender { log_analytics_workspace_id }` で明示的にデプロイ | 下記参照 | 確認済み (スキーマ) |

センサーのデプロイ方法の選択:

| 方法 | 長所 | 短所 |
|------|------|------|
| A. AKS の `microsoft_defender` ブロック (サンプルの方法) | apply 直後に入る。送信先の LAW を明示できる | クラスター定義に Defender の知識が入る |
| B. プランの自動プロビジョニング (`ContainerSensor` 拡張 + Azure Policy) | クラスター側のコードが不要 | 反映まで時間がかかる。Defender が既定のワークスペース (`DefaultResourceGroup-<region>` / `DefaultWorkspace-*`) を自動作成する場合がある |

- A と B を併用したときに、Policy 側が AKS の `securityProfile` を書き換えて **Terraform のドリフト**になるかは要確認
- センサーは各ノードに DaemonSet (`microsoft-defender-collector-*`) として入り、CPU / メモリを使う。サンプルの B2s (2 vCPU / 4 GB) で余裕があるかは要確認
- 価格 API には `Standard Images` (¥45.69/イメージ) という旧来のレジストリスキャン用メーターもある。現行の Containers プランでレジストリ脆弱性評価が追加料金なしで含まれるかは、実際の課金で確認する (要確認)
- azurerm 5.x の AKS では `node_provisioning_profile` ブロックが必須 (確認済み)。Defender とは関係ないが、4.x からの移行時に詰まる

---

## 4. Defender for open-source relational databases (PostgreSQL)

| 設定 | サンプルの値 | 注意点 | 確度 |
|------|-------------|--------|------|
| 対象 SKU | Burstable B1ms | フレキシブルサーバーは**全価格レベル (Burstable 含む) が対象** | ドキュメント |
| 課金 | ¥2,363.25 / サーバー・月 | SKU に関係なく**インスタンス単位の定額**。小さい DB を大量に持つと割高 | 確認済み (価格 API) |
| リソース単位の API | `Microsoft.DBforPostgreSQL/flexibleServers/advancedThreatProtectionSettings@2025-08-01` | 下記参照 | 確認済み (azure-rest-api-specs) |

### azapi が必要な理由

- azurerm (5.10.0) に PostgreSQL フレキシブルサーバー用の Defender 有効化リソースが**無い** (スキーマで確認済み)
- `advancedThreatProtectionSettings/Default` は**サーバー作成時から存在する固定名の子リソース**で、API には CreateOrUpdate / Get / List しかなく **DELETE が無い** (azure-rest-api-specs `PostgreSql/stable/2025-08-01` で確認済み)
- そのため `azapi_resource` (destroy で DELETE を送る) ではなく、**`azapi_update_resource`** で `properties.state` だけを上書きする

`azapi_update_resource` の注意点:

- **destroy では何もしない**。サーバーごと消すなら問題ないが、「サーバーは残して Defender だけ外す」場合は `state = "Disabled"` で apply してからコードから消す必要がある。**コードから消すだけだと Enabled のまま課金が続く**
- API バージョン: `2025-08-01` を使っている。spec には `2026-10-01` もあり、対象サブスクリプションの `flexibleServers` も `2026-10-01` に対応していたが、出たばかりなので見送った
- MySQL フレキシブルサーバーも同じ形 (`Microsoft.DBforMySQL/flexibleServers/advancedThreatProtectionSettings`) の想定 (要確認)

### アラート検証との兼ね合い

- サンプルはシークレットを持たないようにパスワード認証を無効にしている。**ブルートフォース系のアラート (ログイン失敗の繰り返し) はパスワード認証を前提にしている**ので、アラートまで確認したい場合は
  - パスワード認証を一時的に有効にする (パスワードは `administrator_password_wo` (write-only 属性) で渡して state に残さない。azurerm 5.10 のスキーマに存在することは確認済み)
  - または有効化状態の確認だけで終える
  のどちらにするか決める

---

## 5. Defender for Azure Cosmos DB

| 設定 | サンプルの値 | 注意点 | 確度 |
|------|-------------|--------|------|
| 対象 API | NoSQL | Defender for Cosmos DB は **NoSQL API のみ**対応の想定。MongoDB / Cassandra / Gremlin / Table API のアカウントは対象外か要確認 | ドキュメント (要確認) |
| 容量モード | サーバーレス | 価格 API の単価は **100 RU/s・時 (¥0.1891) = プロビジョニング スループット前提**。サーバーレスの課金方法は不明なので請求で確認する | 確認済み (価格) / 要確認 |
| 課金 | プロビジョニング RU/s に比例 | オートスケールの場合は最大 RU/s で課金されるか、実際に使った RU/s で課金されるかを要確認 | 要確認 |
| Terraform | `azurerm_advanced_threat_protection` (`target_resource_id` = アカウント ID) | 汎用リソースで azapi 不要 | 確認済み (スキーマ) |

- 大きな RU/s をプロビジョニングしている本番アカウントでは Defender の費用も比例して大きくなる。サブスクリプション単位で有効化する前に、対象アカウントの RU/s 合計を確認する

---

## 6. シークレット / state

| 項目 | 内容 |
|------|------|
| state に残る機微情報 | Storage / Cosmos DB のアクセスキー (認証を無効にしても azurerm は保存する)。AKS は `local_account_disabled = true` なので静的な認証情報は入らない |
| 本番での state 保管 | ローカル state ではなく、**Entra 認証 + 共有キー無効**の Storage バックエンド (`use_azuread_auth = true`) にする。state 用ストレージ自体も Defender for Storage の保護対象にする |
| write-only 属性 | パスワードが要る場面では `*_wo` 属性 (Terraform 1.11 以降) を使い、state に残さない |
| tfvars | subscription_id / UPN / 接続元 IP は機密度は低いが環境固有なので `.gitignore` 済み |

---

## 7. 運用・ガバナンス (追加の検討項目)

### 7.1 管理の境界 (どの state で持つか)

pricings はサブスクリプションにつき 1 つのシングルトンなので、**複数の Terraform state から同じプランを管理すると互いに上書きし合う**。

| 推奨案 | 内容 |
|--------|------|
| サブスクリプション単位のプラン | プラットフォーム (ランディングゾーン) 側の 1 つの state だけで管理 |
| リソース単位の設定 | 各ワークロードのモジュール内で、リソース本体と一緒に管理 |

- このサンプルは検証のため 1 つにまとめているが、モジュール化する場合はこの 2 つを分ける
- 既に Standard になっているプランを Terraform に取り込む場合、`terraform import` が必要か、そのまま apply で上書きされるかは要確認 (pricings は常に存在するため)

### 7.2 Azure Policy との競合

- 管理グループ / サブスクリプションに「Configure Microsoft Defender for XXX to be enabled」のような **DeployIfNotExists ポリシー**があると、Terraform で Free に戻しても Policy が Standard に戻す (ドリフトになる)
- 対象サブスクリプションの割り当ては `ASC Default` (Microsoft クラウドセキュリティベンチマーク、監査のみ) だけで、DeployIfNotExists 型の Defender 有効化ポリシーは無かった (確認済み)。本番のサブスクリプションでは別途確認する

### 7.3 アラートの受け取りと連携 (サンプル未実装)

| 項目 | Terraform リソース | 内容 |
|------|---------------------|------|
| セキュリティ連絡先 | `azurerm_security_center_contact` | アラートのメール通知先と重大度のしきい値。対象サブスクリプションでは未設定 (確認済み) |
| 連続エクスポート | `azurerm_security_center_automation` | アラート / 推奨事項を LAW や Event Hub に流す。SIEM 連携や長期保存に使う |
| Sentinel 連携 | Defender XDR コネクタ | Sentinel を使う場合 |

### 7.4 権限

| 操作 | 必要な権限の目安 | 確度 |
|------|------------------|------|
| pricings の変更 | サブスクリプションの Security Admin / Contributor / Owner | ドキュメント |
| Storage のマルウェアスキャン有効化 | 上記に加えて、ロール割り当てと Event Grid リソースを作れる権限 | 要確認 |
| サンプルのロール割り当て (AcrPull / AKS RBAC など) | `Microsoft.Authorization/roleAssignments/write` (Owner / User Access Administrator) | 確認済み (リソースの性質上) |

CI/CD のサービスプリンシパルにどこまで権限を渡すかを決めておく。

### 7.5 費用管理

- Defender の課金はプランごとのメーターで請求される。**リソースのタグで Defender 費用を配賦できるか** (コスト分析でリソース ID が付くか) は要確認
- サブスクリプションに予算アラート (`azurerm_consumption_budget_subscription`) を設定しておくと、検証の消し忘れに気付ける
- 費用が大きくなりやすい順に: Containers (ノードの vCore × 時間) > Cosmos DB (プロビジョニング RU/s) > Storage (アカウント数 + マルウェアスキャンの GB) > PostgreSQL (インスタンス数)

### 7.6 関連プランとの関係

- **Defender CSPM** (有料の CSPM プラン): 攻撃パス分析、機密データの可視化、エージェントレスのコンテナー検出などの一部機能は、各ワークロードのプランではなく CSPM 側の機能。このサンプルでは CSPM は有効にしていない。どの機能がどちらのプランのものかは要確認
- **Defender for Servers**: AKS ノード (VMSS) は Servers プランの対象外の想定 (Containers 側で保護)。Servers を有効にしたとき二重課金にならないかは要確認

---

## 8. 未確認事項チェックリスト (apply 後に確認)

- [ ] リソース単位の有効化で無料試用が始まるか / ¥0 のメーターで課金されるか (請求の明細で確認)
- [ ] Cosmos DB サーバーレスの Defender 課金
- [ ] 共有キー無効のストレージでマルウェアスキャンと結果のインデックスタグ書き込みが動くか
- [ ] Defender が自動作成するリソース (Event Grid システムトピック、`DefaultResourceGroup-*`) と、destroy 後に残るもの
- [ ] `extension` を書かなかった拡張の扱い (無効になるか、既存の値が残るか)
- [ ] AKS の `microsoft_defender` ブロックと自動プロビジョニングの併用でドリフトが出るか
- [ ] サブスクリプション単位が Standard のとき、リソース単位で PostgreSQL / Cosmos DB を Disabled にできるか
- [ ] `azapi_update_resource` をコードから消したとき、PostgreSQL の Defender が Enabled のまま残ること (想定どおりか)
- [ ] B2s ノードで Defender センサーのリソース消費に余裕があるか
