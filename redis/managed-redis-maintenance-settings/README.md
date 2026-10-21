# Azure Managed Redis のメンテナンス設定を IaC で管理する検証

Azure Managed Redis (`Microsoft.Cache/redisEnterprise`) の**カスタムメンテナンスウィンドウ**を
Terraform で管理できるか、どう書くかを確認する。

## 結論 (机上調査)

| 項目 | 結果 |
|------|------|
| azurerm (`azurerm_managed_redis`) | **非対応**。v5.10.0 (2026-10 時点の最新) のスキーマにメンテナンス関連属性なし |
| ARM API | `properties.maintenanceConfiguration.maintenanceWindows` で設定可能。2025-08-01-preview で導入、**stable は 2026-09-01** から |
| Terraform での書き方 | **azapi が必要**。本体は azurerm のまま、`azapi_update_resource` で該当プロパティだけ上書きする |

- azurerm のスキーマは `terraform providers schema -json` で確認した (azurerm に `maintenance` を含む属性は
  VM / Dedicated Host 向けの `azurerm_maintenance_*` 系のみで、Managed Redis 向けは無い)
- 対象サブスクリプションで `az provider show -n Microsoft.Cache` を実行し、`redisEnterprise` が
  API 2026-09-01 (および 2026-10-01-preview) に対応していること、Japan East が対応リージョンであることを確認した
- API の定義は [azure-rest-api-specs](https://github.com/Azure/azure-rest-api-specs/tree/main/specification/redisenterprise/resource-manager/Microsoft.Cache/RedisEnterprise/stable/2026-09-01) の `redisenterprise.json` で確認した (preview 版と定義は同じ)
- 旧 Azure Cache for Redis の `patch_schedule` (azurerm_redis_cache) とは別物

### API の形

```jsonc
"maintenanceConfiguration": {
  "maintenanceWindows": [
    { "type": "Weekly", "duration": "PT9H", "startHourUtc": 17, "schedule": { "dayOfWeek": "Friday" } }
  ]
}
```

- `type` は `Weekly` のみ / `startHourUtc` は 0-23 (UTC、正時のみ) / `duration` は ISO-8601
- 制約 (preview)。[公式ドキュメント](https://learn.microsoft.com/azure/redis/scheduled-maintenance) 記載分 + 実機で判明した分:
  **1 ウィンドウ 4〜24 時間 / 週 2 ウィンドウ以上 / 合計 18 時間以上 / 1 曜日 1 ウィンドウ**
  -> `variables.tf` の validation でも検査するので、違反は plan の時点で失敗する

## 構成

| リソース | 管理 | 内容 |
|----------|------|------|
| `amrmnt-rg` | azurerm | 検証用リソースグループ (japaneast) |
| `amr-amrmnt-<suffix>` | azurerm | Azure Managed Redis **Balanced_B0** (最小 SKU) |
| メンテナンス設定 | **azapi** (`azapi_update_resource`) | 上記クラスタの `maintenanceConfiguration` だけを管理 |

全部を `azapi_resource` で書く方法もあるが、既存の azurerm 管理リソースに後付けする場面を想定して
ハイブリッド構成にした。

## 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id を記入
terraform init
terraform apply

terraform output maintenance_configuration    # azapi が読み戻した値
./show-maintenance.sh                         # ARM API から直接読んだ実機の値
```

## 実機検証結果 (2026-10-21)

環境: 検証用サブスクリプション / japaneast / Balanced_B0 / Terraform 1.15.5 / azurerm 5.10.0 / azapi 2.13.0

**結論: azurerm (本体) + azapi_update_resource (メンテナンス設定) の構成で、Terraform からメンテナンス設定を問題なく管理できる。**

| # | 確認内容 | 結果 |
|---|---|---|
| 1 | apply で設定が入るか | ✅ 1 秒で反映、ARM 直読みも一致、再 plan 差分なし |
| 2 | azurerm 側 (tags 変更) で消えないか | ✅ 消えない |
| 3 | ドリフト検出 | ✅ plan で差分検出、apply で復元 |
| 4 | `[]` で解除 | ✅ 解除可 (output を 1 箇所修正) |
| 5 | 制約違反時の API 挙動 | ✅ 400 BadRequest で拒否 |

所要時間: Managed Redis 本体の作成 約 8 分半 / メンテナンス設定の変更 1〜2 秒

### 主な発見

- **#2 は懸念に反して問題なし**: azurerm はメンテナンス設定を知らない API 2025-07-01 で GET -> PUT (全体置換) するが、
  設定は保持された。ただし仕様として明文化された挙動ではなく実機観測なので、
  azurerm のバージョンを上げたときは `./show-maintenance.sh` での確認を推奨する
- **#4 で output のバグを修正**: 解除すると API レスポンスから `maintenanceConfiguration` キー自体が消えるため、
  output の直接参照がエラーになった -> `try()` で対応
- **ドキュメントに無い制約を 2 つ発見**: 1 ウィンドウの**上限は 24 時間**、**同じ曜日に複数ウィンドウは不可**。
  両方とも `variables.tf` の validation に追加し、plan 時点で弾かれることを確認済み
- **apply には MFA 認証済みのログインが必要**: MFA なしの `az login` では
  `401 RequestDisallowedByAzure: ... without authenticating through MFA` で失敗した。
  `az login --tenant <tenant-id> --scope https://management.core.windows.net//.default` で再ログインして解消

### 1. 設定の投入

`terraform.tfvars.sample` の値 (Fri / Sat 17:00 UTC から 9 時間ずつ) で apply し、
`azapi_update_resource` の作成 1 秒で反映された。`./show-maintenance.sh` (API 2026-09-01 での直接 GET) でも同値。

### 2. azurerm の更新でメンテナンス設定が消えないか

**懸念**: azurerm v5.10.0 の `azurerm_managed_redis` は、tags / sku などを変えると
**GET -> PUT (全体置換)** で更新する (`internal/services/managedredis/resources/managed_redis/r_update.go`)。
しかも使う API バージョンは **2025-07-01** で、その型には `maintenanceConfiguration` が無いため、
PUT のボディからメンテナンス設定が落ちる。

**結果**: `locals.tf` の tags を変更して apply (azurerm の PUT が実行される) -> **メンテナンス設定はそのまま残った**。
古い API バージョンの PUT では、そのバージョンに存在しないプロパティを RP 側が保持する挙動が観測された
(仕様として明文化されたものではなく、今回の実機での観測結果)。
その後の plan も `No changes`。

> 将来 azurerm が新しい API バージョンに上がった場合、PUT のボディに `maintenanceConfiguration`
> (未設定 = null) が乗って消える可能性はゼロではない。プロバイダ更新時は plan / apply 後に
> `./show-maintenance.sh` で確認するのが安全。消えた場合も次回 plan で azapi 側に差分が出るので気付ける。

### 3. ドリフト検出

ポータル操作の代わりに API (`az rest --method patch`) で Saturday のウィンドウを Sunday 18:00 / 10 時間に変更。
`terraform plan` で `azapi_update_resource.maintenance` に in-place 更新が出た (`dayOfWeek: "Sunday" -> "Saturday"` など)。
apply で Terraform の定義どおりに戻った。

### 4. 解除

`-var='maintenance_windows=[]'` で apply すると解除される。解除後の API レスポンスでは
**`maintenanceConfiguration` 自体が消える** (空配列ではなくキーが無くなる)。

- 当初の `outputs.tf` は `...output.properties.maintenanceConfiguration` を直接参照していたため
  `Unsupported attribute` エラーになった -> `try(..., null)` で吸収するよう修正済み
- 解除状態で `[]` のまま plan しても `No changes` (空配列と「キー無し」の間で差分は出なかった)

### 5. API の入力チェック (Terraform の validation を通さず API に直接送信)

| 入力 | 結果 | エラーメッセージ (抜粋) |
|------|------|-------------------------|
| 1 ウィンドウのみ (18h) | ❌ 400 | `Please specify at least 2 day(s) across all maintenance windows for the week.` |
| 3h + 15h | ❌ 400 | `The specified duration 'PT3H' is invalid. ... represent a duration between 4 and 24 hours.` |
| 8h + 8h (合計 16h) | ❌ 400 | `Please allocate a total of at least 18 hour(s) per week across all maintenance windows.` |
| `PT30M` | ❌ 400 | 同上 (duration between 4 and 24 hours) |
| 同じ曜日に 2 ウィンドウ | ❌ 400 | `The day 'Monday' is assigned to multiple maintenance windows. Each window must be scheduled on a unique day of the week.` |
| `dayOfWeek` 省略 | ❌ 400 | `'' is not a valid day of week.` |
| 9h + 9h | ✅ | |
| 24h + 24h (Mon 01:00 / Tue 01:00 開始) | ✅ | 24h ちょうどは許容 (2 つのウィンドウは隣接するだけで重なってはいない) |

**ドキュメントに無い制約**: 1 ウィンドウの**上限 24 時間**、**1 曜日 1 ウィンドウ**。
どちらも `variables.tf` の validation に追加し、該当する値で plan がエラーになることを確認済み。
(当初の validation (4h 以上 / 2 ウィンドウ以上 / 合計 18h 以上) も、3h + 3h の値で plan エラーになることを確認済み)

エラーメッセージに「only hour and minute components」とあるため `PT4H30M` のような分単位指定は
受け付ける可能性があるが未検証。本コードの変数は時間単位 (整数) に限定している。

この検証は `az rest` で直接上書きしたため、最後に `terraform apply` で sample の値 (Fri / Sat) に戻し、
plan が `No changes` になることを確認した。

### その他の所見

- azapi 2.13.0 は API 2026-09-01 の型を内蔵しており、`schema_validation_enabled = false` は不要だった
- ログは `out/` に保存 (実リソース ID を含むため git 管理外)
- `terraform destroy` しても `azapi_update_resource` はメンテナンス設定を元に戻さない (リソースごと消すので今回は問題ない)。
  本体を残したまま設定だけ外したい場合は `maintenance_windows = []` で apply する

### 未検証の項目

- ポータルの「Maintenance (Preview)」画面での表示・ポータルからの変更 (#3 は `az rest` の PATCH で代用した)
- 実際にメンテナンスがスケジュールどおりに実行されるか (Activity Log の `healthevent` などでの確認)
- メンテナンス設定の変更がクラスタの可用性・接続に影響するか (今回は変更が 1〜2 秒で完了したことのみ確認)
- 分単位の duration (`PT4H30M` など)
- `azapi_resource` で本体ごと azapi 管理にする構成

### 検証後の状態

検証用リソース (`amrmnt-rg` / `amr-amrmnt-5n4evx`) は sample の値 (Fri / Sat 17:00 UTC から 9 時間ずつ) を
設定した状態で残してある (課金継続中)。不要になったら下記で削除する。

## 後片付け

```bash
terraform destroy
```
