# デプロイ時のトラブルシュート / ナレッジ

本構成を実際に apply する過程で踏んだ問題と対処を記録する。
新規・制限付きサブスクリプションや、Azure 固有のプロバイダ事情に起因するものが多い。

---

## 1. 【最重要】ADF→PostgreSQL の AAD 認証が `typeProperties: {}` で 400

### 症状
`azurerm_data_factory_linked_custom_service`（type=`AzurePostgreSql`, version=`2.0`,
`authenticationType=SystemAssignedManagedIdentity`）で apply すると:

```
Status=400 ... "typeProperties": {} ... error is Invalid linked service payload,
the 'typeProperties' nested in payload is null.
```

`type_properties_json` に正しい JSON を入れているのに、Azure へ送られる payload の
`typeProperties` が**空**になる。`version` だけは `additional_properties` 経由で載る。

### 原因
**azurerm プロバイダのバグ** ([azurerm #29379](https://github.com/hashicorp/terraform-provider-azurerm/issues/29379))。
`azurerm_data_factory_linked_custom_service` が `type_properties_json` の中身を
payload に載せ損ねる。**azurerm 3.117 → 4.76 でも再現**＝バージョン更新では直らない。
送信している JSON 自体は [Microsoft Learn 公式例](https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/how-to-connect-data-factory) と一致しており正しい。

### 対処（採用: azapi で生 ARM JSON を投入）
ADF のリンクサービスだけ `azapi_resource` で作る（`terraform/modules/data_factory`）。
ADF 本体・IR・Managed PE・データセット・パイプラインは azurerm のまま。

```hcl
resource "azapi_resource" "ls_psql" {
  type                      = "Microsoft.DataFactory/factories/linkedservices@2018-06-01"
  name                      = "ls_psql"
  parent_id                 = azurerm_data_factory.main.id
  schema_validation_enabled = false
  body = { properties = {
    type = "AzurePostgreSql", version = "2.0", annotations = []
    typeProperties = { server = var.psql_fqdn, port = 5432, database = var.psql_database_name,
                       sslMode = 2, authenticationType = "SystemAssignedManagedIdentity" }
    connectVia = { referenceName = "ManagedVnetIR", type = "IntegrationRuntimeReference" }
  }}
}
```

- `azapi` プロバイダ（`Azure/azapi`）を `providers.tf` に追加。
- データセットは `linked_service { name = azapi_resource.ls_psql[0].name }` で参照。
- 接続先 PG に ADF の MI（表示名 = `ci00-adf`）の AAD ロールが必要（`create-tables.sql`）。
- 検証は ADF Studio の **Test connection**。

### 検討した他案
- 案A: ADF Studio で手動作成 → IaC 管理外（drift）。
- 案B: SQL 認証（`azurerm_data_factory_linked_service_postgresql`）→ 確実だが ADF だけパスワード認証。

---

## 2. PostgreSQL を Single Server → Flexible Server へ（AAD 化に伴い）

- Single Server は AAD 連携が扱いにくく旧世代。Flexible Server を採用。
- **ネットワークは Private Endpoint 方式**（`public_network_access_enabled = false`＋PE、VNet 注入は不使用）。
  - 理由: VNet 注入（委任サブネット）方式だと **ADF の Managed Private Endpoint から到達できない**。
    PE 方式なら ADF Managed PE（`postgresqlServer`）からも Function の VNet 統合からも届く。
- 認証: `authentication { active_directory_auth_enabled = true, password_auth_enabled = true }`。
  SQL 管理者は bootstrap / break-glass 用に併存。

---

## 3. App Service (Functions EP1) のクォータが 0

### 症状
`azurerm_service_plan`（EP1）で
`Operation cannot be completed without additional quota ... Current Limit (Total VMs): 0`。

### 対処
Functions は VNet 統合 + PE のため **EP1（Elastic Premium）必須**（SKU 引き下げ不可）。
Portal の「使用量 + クォータ → App Service → Japan East」で以下を申請（3 程度、小さい値は自動承認されやすい）:
- **`EP1 VMs`**（使用 SKU）
- **`Total Regional VMs`**（リージョン合計。0 だと EP1 を上げても同じエラー）

---

## 4. AKS / VM のサイズがサブスクリプションで不可

### 症状
`The VM size of Standard_DS2_v2 is not allowed in your subscription in location 'japaneast'`。

### 対処
- 許可リスト内のサイズを指定（本構成の既定は `Standard_D2s_v3`）。`az vm list-skus -l japaneast` で確認。
- **注意**: `terraform.tfvars` に `aks_node_size` を書いていると **default を上書き**する。
  コードの default だけ変えても効かないので tfvars 側も直す。
- 踏み台 VM（`jumpbox_vm_size`、既定 `Standard_B1s`）も同様に不可なら変更。

---

## 5. Storage の `network_rules` に `/32` を指定すると失敗

### 症状
`"network_rules.0.ip_rules.0" must start with IPV4 address and/or slash, number of bits
(0-30) as prefix ... but got "<CLIENT_GLOBAL_IP>/32"`。

### 対処
Storage の IP ルールは **単一 IP を裸で指定**（`<CLIENT_GLOBAL_IP>`）。範囲は **/0〜/30**（/31, /32 は不可）。
`terraform.tfvars` の `allowed_upload_ip` を裸 IP にする。

---

## 6. （廃止）AAD アプリの identifier URI がテナントポリシーで拒否

> **現在は該当しません。** AKS → Function の認証を **Function キー方式** に変更し、
> Easy Auth / AAD アプリ登録（`aad.tf`）を撤去したため、identifier URI に関する本問題は発生しません。
> 以下は AAD 認証を採用していた旧構成の記録です。

### 症状（旧構成）
`InvalidUniqueTenantIdentifierAsPerAppPolicy: Failed to add identifier URI api://ci00-func.
All newly added URIs must contain a tenant verified domain, tenant ID, or app ID`。

### 対処（旧構成）
- identifier URI を **テナントID 修飾**にする: `api://<tenant-id>/ci00-func`。
- アプリに **アクセストークン v2** を付与: `api { requested_access_token_version = 2 }`。
- Easy Auth の `allowed_audiences` は URI と client_id の両方を許可。

---

## 7. azurerm 3 → 4 メジャー更新の破壊的変更

provider を `~> 4.0` に上げた際に出た非互換（`validate` で検出）:

| 変更 | 旧 (3.x) | 新 (4.x) | 場所 |
| --- | --- | --- | --- |
| AKS ノードプール | `enable_auto_scaling` | `auto_scaling_enabled` | `aks.tf` |
| Storage コンテナ | `storage_account_name` | `storage_account_id`（`.name`→`.id`） | `storage.tf` |

> `azurerm_storage_blob` の `storage_account_name` は 4.76 時点では非推奨化されておらず変更不要（5.0 で対象）。

---

## 8. バージョン固定方針（パッチのみ自動更新）

`providers.tf` は最新に固定し、3 桁 `~>` でパッチのみ自動更新:

- Terraform 本体: `required_version = "~> 1.15.5"`
- azurerm `~> 4.76.0` / azuread `~> 3.8.0` / azapi `~> 2.10.0` / random `~> 3.9.0`

> CLI 側（mise 等）も `required_version` を満たす版にしておくこと。満たないと全コマンドが
> `Unsupported Terraform Core version` で止まる。

---

## 9. 新規サブスクリプション直後の一時的な apply ハング / 認証エラー

- 新しく作成したサブスクリプションは Azure CLI に認識されず
  `the provided subscription ID ... is not known by Azure CLI` → `az login` で解消。
- 再ログイン直後に plan/apply が無応答になることがあるが一時的。
  `az account get-access-token` が即返り、必要 Resource Provider が `Registered` なら
  作り直し（plan 再実行）で解消することが多い。

---

## 10. ADF の Managed Private Endpoint は手動承認が必要

`azurerm_data_factory_managed_private_endpoint` は接続**リクエスト作成のみ**。
ターゲット（Storage / PostgreSQL）側で **承認**するまで通信が通らない（特に cross-subscription の PG）。
手順は [README の「3-b. ADF の Managed Private Endpoint を承認」](../README.md) を参照。

---

## 11. `pgaadauth_create_principal does not exist`（AAD ロール作成）

### 症状
appdb で `create-tables.sql` を実行すると
`ERROR: function pgaadauth_create_principal(...) does not exist`。

### 原因
**`pgaadauth_*` 関数は特別な `postgres` データベースにしか存在しない**
（[MS Q&A](https://learn.microsoft.com/en-us/answers/questions/1655608/)）。appdb 等では使えない。
加えて MI（サービスプリンシパル）は名前ベースの `pgaadauth_create_principal` だと
Microsoft Graph 権限が要り失敗しやすい。

### 対処
- ロール作成（`pgaadauth_create_principal_with_oid`）は **`postgres` DB** で実行
  （`apps/psql/.../create-aad-roles.sql`）。ロールはクラスタ共有なので appdb から参照可。
- テーブル + GRANT + 所有権付与は **`appdb`** で実行（`create-tables.sql`、pgaadauth は含めない）。
- MI は **`_with_oid`（object_id 明示・`'service'`）** で作成し Graph 依存を回避。
  object_id は terraform output（`data_factory_principal_id` / `function_principal_id` /
  `jumpbox_principal_id`）から取得。

---

## 12. （旧構成）`2BP01: cannot drop table ... because other objects depend on it` で Failed

> **現在は発生しません。** 参照ビュー（旧 `view_prd_table`）を廃止したため、本番テーブルへの
> 依存オブジェクトが無くなり、入替の `DROP TABLE` がビュー依存で失敗することはありません。
> 以下は view 併存時（旧構成）の記録です。

### 症状（旧構成）
CSV アップロードでトリガーは正常発火（Trigger run = Succeeded）するのに、
`pl_csv_ingest` の `ValidateData`（Script Activity）が Failed:

```
Operation on target ValidateData failed: 2BP01: cannot drop table prd_table
  because other objects depend on it
```

トリガー自体は動いているので「パイプラインが走っていない」と誤認しやすい。
`az datafactory trigger-run query-by-factory`（発火履歴）と
`az datafactory pipeline-run query-by-factory --query value[].message`（失敗理由）を
**両方**見ると切り分けられる。

### 原因（旧構成）
本番テーブル入れ替えの SQL が `DROP TABLE` を実行するが、**ビューが本番テーブルに依存**
しているため PostgreSQL が drop を拒否していた（view を先に落とす必要があった）。

### 現構成での扱い（案11: production 永続化・UPSERT+DELETE 同期）
view を廃止し、さらに **DROP/RENAME swap も廃止**。入替トランザクションは
`INSERT … FROM customer_info_staging ON CONFLICT (policy_no) DO UPDATE … → DELETE … WHERE policy_no NOT IN (SELECT … FROM staging)` のみ。
production を drop しないので 2BP01（依存オブジェクト）も rename も無い。
**SELECT 権限は create-tables.sql の初回 GRANT で恒久化**され、validation.sql での再付与は不要
（旧 rename 方式では権限が引き継がれず末尾で毎回再 GRANT していた）。

### 再実行（手動）
トリガー無しで検証する場合、Copy 元データセットが `triggeredFileName` パラメータを
参照するため、失敗 run のパラメータからファイル名を取得して渡す:

```bash
az datafactory pipeline-run show -g <HUB_RG> --factory-name <ADF> \
  --run-id <FAILED_RUN_ID> --query parameters    # triggeredFileName を確認
az datafactory pipeline create-run -g <HUB_RG> --factory-name <ADF> \
  --name pl_csv_ingest --parameters '{"triggeredFileName":"ciupload39.csv"}'
```

---

## 13. バリデーション設計: 列長超過の hard fail 回避 + NULL 3値論理の取りこぼし回避

ここは**現行の設計（landing/error は VARCHAR(255) + SQL 全チェック）で両方とも解消済み**。経緯と対処を記録する。

### 課題1: 列長超過の hard fail（解消済み）
旧構成では `customer_info_landing` が厳格型（`VARCHAR(10/100/8/15)`）で、**policy_no 11 文字**等の超過値は
`InputCSV` の Sink で `22001: value too long` となり **pipeline 全体が Failed**（検証に到達しない）。
- **対処**: `customer_info_landing`（および `customer_info_error`）の列を **`VARCHAR(255)`**（寛大上限・NULL 可）に変更。
  超過値も landing に入り、検証 SQL の桁数チェック（`char_length(policy_no) > 10` 等）で
  `policy_no too long (max 10)` として `customer_info_error` に振り分けられる。**Fail しなくなった。**
  （255 超の異常値のみロード段階で 22001。現実データでは起きない）

### 課題2: NULL/空行の取りこぼし（解消済み）
CSV の空フィールドは Copy で **NULL / 空文字**としてロードされる。素朴な
`WHERE NOT (policy_no ~ regex AND …)` だと、NULL を含む行は3値論理で**どちらの INSERT にも入らず消える**。
- **対処**: 現行の検証 SQL は CTE `judged` で各行の `format_error` を CASE で算出し
  （先頭に `policy_no IS NULL OR policy_no = ''` → `policy_no required`)、OK=`format_error IS NULL`、NG=`format_error IS NOT NULL`
  と**厳密な補集合**で振り分ける。NULL/空行も確実に error へ入る。

```sql
WITH judged AS (
  SELECT policy_no, name_kana, birth_ymd, cellular_phone_no,
    CASE WHEN policy_no IS NULL OR policy_no = '' THEN 'policy_no required'
         WHEN char_length(policy_no) > 10  THEN 'policy_no too long (max 10)'
         ... END AS format_error,
    count(*) OVER (PARTITION BY policy_no) AS id_count   -- policy_no 重複検出
  FROM customer_info_landing
), promote_ok AS (
  INSERT INTO customer_info_staging SELECT ... FROM judged WHERE format_error IS NULL AND id_count = 1
)
INSERT INTO customer_info_error SELECT ..., COALESCE(format_error,'policy_no duplicated')
  FROM judged WHERE format_error IS NOT NULL OR id_count > 1;
```

### 失敗ケースの作り方
`apps/storage/script-for-generating-sample-csv/generate_invalid_csv.py` が
違反 CSV を `./csv` 配下に**意図ごとのファイル名**で生成する（policy_no 空欄 / 氏名ひらがな / 生年月日 7 桁 /
電話ハイフン無し / **policy_no 桁数超過** / **policy_no 重複**）。いずれも pipeline は **Succeeded** で、違反行は
`customer_info_error` に該当理由付きで振り分けられる。`upload-csv-to-blob.sh` で投入できる。
（手順・確認は [pipeline.md](./pipeline.md) §6 / README「失敗ケース（バリデーション NG）の確認」も参照）

---

## 14. バリデーションエラーがあっても `pl_csv_ingest` は Succeeded（仕様）

バリデーションエラー（`customer_info_error` に行あり）があっても、`pl_csv_ingest` は **Succeeded** になり、
ADF Monitor 上に Failed Activity は出ない。これは現行の仕様。

- 現構成は `InputCSV` → `ValidateData` → `ArchiveSuccess` / `ArchiveError`（並列）の 4 アクティビティで、
  すべて正常に完了すればパイプラインは Succeeded。
- エラー行の有無は **Activity の成否では分からない**。`customer_info_error` テーブル、または
  `ArchiveError` が出力する `ciarchive39container/archive/error/error_*.csv`（ヘッダのみ＝エラー無し）で確認する。

> 補足: 以前は `FailOnValidationError`（Fail Activity）を意図的に Failed にして
> `azure_datafactories_ActivityFailedRuns` メトリックでバリデーションエラーを検知する構成だったが、
> 見通し簡素化のため**廃止**した（`LookupErrorCount` / `IfErrorsExist` / `FailOnValidationError` /
> `IgnoreValidationFailure` を削除）。メトリック/ログによるアラートが必要なら、
> `customer_info_error` の行数監視など別経路で実装する。

---

## 15. ADF パイプラインの恒常 diff（`compressionProperties`）と抑止方法

`azurerm_data_factory_pipeline.this["pl_csv_ingest"]` が毎回 in-place update の差分を出す
（`InputCSV` の `source.formatSettings` から `compressionProperties = { Type = "", Values = null }`
を削除しようとする）ことがある。**挙動は無害**（圧縮なし＝省略時と同義）だが plan ノイズになる。

- 原因: ソース `pipeline.json` の `formatSettings` を最小定義にしても、Azure(ADF) が API 応答時に
  既定値 `compressionProperties = { Type = "", Values = null }` を補完して返すため。
  provider は `activities_json` を**構造比較**するので「リモートにだけ在るキー」を毎回消そうとして収束しない。
- local 経由（`jsonencode`/`jsondecode` 正規化）では消えない。原因は表現揺れでなく**キーの有無**のため。
- 抑止策: ソース JSON に Azure の返り値と**同形の空ブロック**を足して一致させる。casing は
  Azure の返り値どおり **PascalCase**（`Type` / `Values`）が当たり。これでリモートと一致し、
  apply 不要でその場で `0 to change` に収束する（リモートが既にその形のため）。

```json
"formatSettings": { "type": "DelimitedTextReadSettings", "compressionProperties": { "Type": "", "Values": null } }
```

> ⚠️ この空ブロックは恒常 diff 抑止が目的。「不要に見えるから」と**削除すると diff が再発**する。
> JSON はコメント不可のため意図をコード上に残せない。削除しないこと。
> `ignore_changes = [activities_json]` は本当の変更まで無視するので採用しない。

---

## 16. 実在日チェックの `to_date` が無効日で例外 → Script ごとクラッシュ（整数演算で回避）

### 症状

`birth_ymd` に「**8 桁数字だが実在しない日付**」（例 `20260230`=2月30日 / `20260431`=4月31日）を
含む CSV を投入すると、`ValidateData` が次のエラーで **Failed** し、`pl_csv_ingest` 全体が Failed になる
（`ArchiveSuccess` / `ArchiveError` は SKIP、`customer_info_production` も更新されない）。

```
22008: date/time field value out of range: "20260230"
```

桁数違反（7 桁等）は手前の桁数/形式チェックで弾かれるため発症しない。**8 桁数字を満たすが暦上存在しない
日付**だけが地雷で、カタログ 8 種には含まれないので長く潜伏しうる。

### 原因

実在日チェックを `to_date` の round-trip で書いていた:

```sql
-- ❌ 旧: to_date が「繰り上げる」前提。月1-12/日1-31 のレンジガードでは Feb30/Apr31 を防げない
WHEN substring(birth_ymd,5,2)::int NOT BETWEEN 1 AND 12
  OR substring(birth_ymd,7,2)::int NOT BETWEEN 1 AND 31 THEN '...'
WHEN to_char(to_date(birth_ymd,'YYYYMMDD'),'YYYYMMDD') <> birth_ymd THEN '...'
```

- 「`to_date('20260230')` は `2026-03-02` に繰り上がる」想定だったが、**この PostgreSQL（Azure Database
  for PostgreSQL Flexible Server）では繰り上げず `22008` を投げる**。
- レンジガード（日 ≤ 31）は **2/30・4/31・6/31・平年2/29 など「日≤31だが実在しない日」を通す**ため、
  `to_date` に到達して例外 → Script 停止。
- **SQL の `CASE` / 素の式では例外を捕捉できない**（捕捉できるのは PL/pgSQL の `EXCEPTION` ブロックのみ）。
  `'...'::date` / `make_date()` も無効日で同じく throw する。PostgreSQL に「失敗時 NULL を返す安全な
  日付パース」の組込みは無い。
- 検証シミュレータ（`docs/test.md` の Python `datetime`）は無効日で例外を**捕捉してエラー文字列**にするため、
  実機（PG はクラッシュ）と挙動が乖離し、シミュレータだけだと**誤った安心**を生む。

### 対処（採用: 例外を投げない整数演算）

`to_date`/`::date` を使わず、**月ごとの日数＋完全グレゴリオ閏年を整数比較だけ**で判定する
（どんな入力でも throw しない＝Script が落ちない）。実コードは
[`validation.sql`](../terraform/envs/hub-subscription/files/adf_pipeline/customer_info_registration/queries/validation.sql)
の実在日チェック CASE を参照。要点:

```sql
-- ✅ 新: 日 > 「その月の最大日数」を整数比較。2月は (年%4=0 AND 年%100<>0) OR 年%400=0 で 29/28
WHEN substring(birth_ymd,5,2)::int NOT BETWEEN 1 AND 12
  OR substring(birth_ymd,7,2)::int < 1
  OR substring(birth_ymd,7,2)::int >
       CASE substring(birth_ymd,5,2)::int
         WHEN 2 THEN CASE WHEN (...閏年判定...) THEN 29 ELSE 28 END
         WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30
         ELSE 31 END
    THEN 'birth_ymd is not a valid calendar date'
```

### 検証

- ローカル: 新ロジックを Python で同一実装し `datetime.date` と 1880–2035 全 年×月×日（69,888 通り）突合 → 一致。
- ライブ: `20260230`/`20260431` を含む CSV で **Succeeded・error=2**、境界 9 種（閏年 2024/2000=OK・
  **1900=NG（世紀非閏）**・2000=OK・月末 4/30・5/31=OK / 6/31・4/31・2/30=NG）も実機で正しく振り分け。

---

## 関連

- 認証・権限: [auth.md](./auth.md)
- ネットワーク・閉域化: [network.md](./network.md)
- ADF 取り込みパイプライン（構成・確認手順）: [pipeline.md](./pipeline.md)
