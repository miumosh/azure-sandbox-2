# Microsoft Defender for Cloud (Storage / Containers / Databases) を IaC で有効化する検証

Defender for Cloud の次の 4 プランを Terraform で有効化する書き方と、有効化後の挙動を確認する。
実装・設定値の注意点と検討項目は [CONSIDERATIONS.md](CONSIDERATIONS.md) にまとめた。

| 対象 | Defender プラン (pricings の name) | 有効化の単位 | Terraform リソース |
|------|------------------------------------|--------------|--------------------|
| Storage | Defender for Storage (`StorageAccounts` / subplan `DefenderForStorageV2`) | **リソース単位** | `azurerm_security_center_storage_defender` |
| Containers | Defender for Containers (`Containers`) | **サブスクリプション単位のみ** | `azurerm_security_center_subscription_pricing` + AKS の `microsoft_defender` ブロック |
| PostgreSQL | Defender for open-source relational databases (`OpenSourceRelationalDatabases`) | **リソース単位** | `azapi_update_resource` (`flexibleServers/advancedThreatProtectionSettings/Default`) |
| Cosmos DB | Defender for Azure Cosmos DB (`CosmosDbs`) | **リソース単位** | `azurerm_advanced_threat_protection` |

- `enable_subscription_level_plans = true` にすると、Storage / PostgreSQL / Cosmos DB もサブスクリプション単位
  (`azurerm_security_center_subscription_pricing`) で有効化する。**サブスクリプション内の既存リソースも課金対象になる**ため既定は `false`
- azurerm には PostgreSQL フレキシブルサーバー用の Defender リソースが無い (v5.10.0 のスキーマで確認済み) ため azapi で補う。
  `advancedThreatProtectionSettings/Default` はサーバー作成時から存在する固定名の子リソースで、API に DELETE が無いため
  (azure-rest-api-specs `PostgreSql/stable/2025-08-01`) `azapi_update_resource` で `state` だけ上書きする

## 構成

| ファイル | 内容 |
|----------|------|
| `defender_plans.tf` | サブスクリプション単位の Defender プラン (`for_each` で必要な分だけ) |
| `storage.tf` | StorageV2 (LRS) + コンテナー `upload` + リソース単位の Defender for Storage (マルウェアスキャン / 機密データ検出) |
| `containers.tf` | AKS (B2s × 1 ノード / Defender センサー) + ACR Basic + Log Analytics |
| `postgresql.tf` | PostgreSQL フレキシブルサーバー B1ms (v16 / 32 GB / Entra 認証のみ) + Defender 有効化 |
| `cosmosdb.tf` | Cosmos DB NoSQL サーバーレス + DB / コンテナー + Defender 有効化 |

`targets` 変数で対象ごとに作成をオン / オフできる (既定はすべてオン)。

## シークレットの扱い

流出させる値そのものを持たない構成にしてある。

| 対象 | 対策 |
|------|------|
| PostgreSQL | **パスワード認証を無効化**し Entra 認証のみ。管理者パスワードを変数にも state にも持たない |
| Storage | 共有キー認証を無効化 (`shared_access_key_enabled = false`)。provider も `storage_use_azuread = true` で Entra 認証 |
| Cosmos DB | キー認証を無効化 (`local_authentication_enabled = false`)。データ操作は Cosmos DB データプレーン RBAC |
| AKS | ローカルアカウントを無効化 (`local_account_disabled = true`)。Entra ID + Azure RBAC のみで、kubeconfig に静的な認証情報が入らない |
| ACR | 管理者ユーザーを無効化 (`admin_enabled = false`) |
| outputs | キー / 接続文字列は出力しない |

それでも残るリスクと対策:

- **state には Storage / Cosmos DB のアクセスキーが平文で入る** (認証を無効にしても azurerm は保存する)。
  state はローカルのみで、`.gitignore` で `*.tfstate*` / `*.tfplan` を除外している
- `terraform.tfvars` (subscription_id / UPN / 接続元 IP) も `.gitignore` 済み。テンプレートは `terraform.tfvars.sample`
- このディレクトリ単体の `.gitignore` で除外しているので、ディレクトリを切り出しても漏れない

## 費用見積もり (2026-10-28 時点、Azure Retail Prices API の japaneast / JPY 定価)

前提: 既定値 (`targets` すべて true / `enable_subscription_level_plans = false`)。1 か月は 730 時間で換算。

### Defender プラン

| プラン | 単価 | この構成での課金量 | 1 時間あたり |
|--------|------|--------------------|-------------:|
| Storage | ¥2.1112 / アカウント・時 | 1 アカウント | ¥2.11 |
| Storage マルウェアスキャン | ¥23.63 / GB | テストファイルのみ (上限 1 GB/月) | ≒ ¥0 (最大 ¥23.6/月) |
| Containers | ¥1.4825 / vCore・時 | B2s 1 台 = 2 vCore | ¥2.97 |
| PostgreSQL | ¥2,363.25 / サーバー・月 | 1 サーバー | ¥3.24 |
| Cosmos DB | ¥0.1891 / 100 RU/s・時 | サーバーレス (プロビジョニング RU 無し) | ≒ ¥0 ※ |
| **小計** | | | **¥8.3** |

※ 単価はプロビジョニング スループットに対するもので、サーバーレスの課金方法は価格 API からは読み取れなかった。実機の課金で確認する。

**無料試用について**: `az security pricing list` で 4 プランすべて `freeTrialRemainingTime = 30 days` (未使用) だった。
価格 API に ¥0 の Trial 用メーターがあるので、試用が適用されれば Defender 分は ¥0 になる見込み。
ただし次の点は未確認:

- リソース単位で有効化した場合に試用期間が始まるか (Containers はサブスクリプション単位なので確実に始まり、**30 日の試用を消費する**)
- マルウェアスキャン (GB 課金) にも試用が適用されるか (Trial メーターは存在する)

### 検証用インフラ

| リソース | 単価 | 1 時間あたり |
|----------|------|-------------:|
| AKS ノード Standard_B2s × 1 (コントロールプレーンは Free) | ¥8.57 / 時 | ¥8.57 |
| AKS OS ディスク Premium SSD P4 (32 GB) | ¥956.71 / 月 | ¥1.31 |
| AKS の Standard Load Balancer | 約 ¥3.9 / 時 (USD 定価 $0.025 からの概算) | ¥3.9 |
| AKS の送信用パブリック IP (Standard) | ¥0.7877 / 時 | ¥0.79 |
| ACR Basic | ¥26.25 / 日 | ¥1.09 |
| PostgreSQL B1ms | ¥4.0963 / 時 | ¥4.10 |
| PostgreSQL ストレージ 32 GB | 約 ¥640 / 月 (概算) | ¥0.88 |
| Log Analytics | ¥526 / GB (日次上限 0.1 GB。月 5 GB の無料枠内に収まる見込み) | ≒ ¥0 (最大 ¥2.2) |
| Cosmos DB サーバーレス / ストレージアカウント | 従量 (検証の操作量ではごく少額) | ≒ ¥0 |
| **小計** | | **約 ¥20.6** |

### 合計

| 期間 | 定価 (試用なし) | 試用が適用された場合 |
|------|----------------:|---------------------:|
| 1 時間 | 約 ¥29 | 約 ¥21 |
| 半日 (4 時間) | 約 ¥120 | 約 ¥85 |
| 1 日 (24 時間) | 約 ¥700 | 約 ¥500 |
| 1 週間放置 | 約 ¥4,900 | 約 ¥3,500 |

- 費用のおよそ 7 割は AKS (ノード + LB + ディスク)。不要なら `targets = { containers = false }` で外す
- `enable_subscription_level_plans = true` にすると既存のストレージアカウント 2 つ分 (+¥4.22/時) が加わる
- 外部 API で取れなかった LB / PostgreSQL ストレージは USD 定価からの概算 (1 USD ≒ ¥154 で換算)

## 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id / postgresql_entra_admin_upn を記入
terraform init
terraform plan
terraform apply

terraform output                               # 機微情報は含まない
eval "$(terraform output -raw verify_pricing_command)"
```

## 確認したいこと (検証項目案)

公式ドキュメントに書かれている手順。実機ではまだ確認していない。

| 対象 | 確認内容 | 方法 |
|------|----------|------|
| Storage | アップロード時マルウェアスキャンの結果 | EICAR テストファイルを `az storage blob upload --auth-mode login` でアップロードし、BLOB インデックスタグ `Malware Scanning scan result` とアラートを確認 |
| Storage | リソース単位の設定がサブスクリプション設定より優先されるか | `enable_subscription_level_plans` を切り替えて `az rest` で `defenderForStorageSettings/current` を見る |
| Containers | Defender センサーのデプロイ | `az aks get-credentials` → `kubectl get ds -n kube-system \| grep microsoft-defender` |
| Containers | 実行時アラート | ドキュメントのテストアラート手順 (Pod 内でテスト用ファイル名のバイナリを実行) |
| Containers | ACR イメージの脆弱性評価 | 古いタグのイメージを push し、推奨事項に出るまでの時間を見る |
| PostgreSQL | 有効化状態 | `terraform output postgresql_defender_state` / ポータルのサーバー > Defender for Cloud |
| Cosmos DB | 有効化状態 | `az security atp cosmosdb show` |
| 共通 | destroy 後の状態 | pricings が Free に戻るか / Defender が自動作成したリソース (Event Grid システムトピック、`DefaultResourceGroup-*` 等) が残らないか |

## 注意

- `azurerm_security_center_subscription_pricing` を destroy するとそのプランは **Free に戻る**。
  他の検証や本番相当のリソースが同じサブスクリプションで同じプランを使っている場合は影響する
- PostgreSQL のブルートフォースアラートは失敗ログインの繰り返しで発生する想定だが、この構成はパスワード認証が無効なので
  シナリオの見直しが必要
- AKS 5.x の azurerm では `node_provisioning_profile` ブロックが必須 (`mode = "Manual"` で NAP を使わない)
