# ADF データ取り込みパイプライン（ingest）整理

CSV アップロード → ADF パイプライン `pl_csv_ingest` → PostgreSQL `customer_info_production` の
**自動取り込み**の仕組み・設計・落とし穴・確認手順をまとめる。
**バリデーション結果（成功/エラー）はそれぞれ CSV としてアーカイブに出力する**（§7 参照）。
エラー行があってもパイプラインは **Succeeded** のまま（エラーは `customer_info_error` テーブル + `archive/error/*.csv` で確認する）。

定義ファイル:
- パイプライン定義（外出し JSON テンプレート）: `terraform/envs/hub-subscription/files/adf_pipeline/customer_info_registration/pipeline.json`
- Script Activity の検証 SQL: `terraform/envs/hub-subscription/files/adf_pipeline/customer_info_registration/script_activity.sql`
- データセット/トリガー定義: `terraform/modules/data_factory`（トリガー `trg_csv_uploaded` = `input/` への `.csv` 作成で起動）

---

## 1. 全体構成

```
[Storage Explorer/SAS] --input/ciupload39.csv--> [Storage Blob]
        |  BlobCreated イベント
        v  (Event Grid 経由)
[ADF トリガー trg_csv_uploaded (BlobEventsTrigger)]  --triggeredFileName--> 起動
        v
[pl_csv_ingest]
   InputCSV ──> ValidateData ──┬──> ArchiveSuccess
   (CSV→landing) (検証+prod同期)  │    (production → success CSV)
                                 └──> ArchiveError
                                      (error → error CSV)
        v
[PostgreSQL customer_info_production] <--x-functions-key-- [Functions POST /api/customers/search] <--form-- [AKS person-id-app]
```

> **検証結果のアーカイブ**: `ValidateData` の成功後、`ArchiveSuccess` と `ArchiveError` を**並列・無条件**で実行し、
> `customer_info_production` / `customer_info_error` をそれぞれ CSV としてアーカイブに出力する。
> エラー行が無い回も `ArchiveError` は実行され、ヘッダのみ（空）の error CSV が出力される。
> **パイプラインは常に Succeeded**（意図失敗による検知シグナルは持たない）。

### アクティビティ（`pl_csv_ingest`）

| 順 | Activity | 種別 | 役割 | 依存条件 |
| --- | --- | --- | --- | --- |
| 1 | `InputCSV` | Copy | CSV を `customer_info_landing` へロード（`preCopyScript=TRUNCATE customer_info_landing`、CSV ヘッダ名→列名でマッピング: 顧客_番号→policy_no 等） | - |
| 2 | `ValidateData` | Script | 検証 SQL を実行（OK→`customer_info_staging` / NG→`customer_info_error`、トランザクションで `customer_info_production` へ UPSERT+DELETE 同期） | 1 Succeeded |
| 3 | `ArchiveSuccess` | Copy | `customer_info_production`→`archive/success/` CSV 出力 | 2 Succeeded |
| 4 | `ArchiveError` | Copy | `customer_info_error`→`archive/error/` CSV 出力（エラー行が無くてもヘッダのみ出力） | 2 Succeeded |

> ※ `ArchiveSuccess` / `ArchiveError` は `ValidateData` 成功後に並列実行され、エラー有無に関わらず両方走る。

> **並行制御**: `pl_csv_ingest` は `concurrency = 1`。短間隔で複数 CSV が配置されても run は**キューイングされ直列実行**される。
> これにより `InputCSV` の `TRUNCATE customer_info_landing` や `ValidateData` の staging 再投入・production への UPSERT/DELETE 同期が並行 run と競合しない。
>
> **検証 SQL の受け渡し**: `queries/validation.sql` は TF が pipeline parameter `validation_sql` の default として渡し、
> `ValidateData` の `"text": "@{pipeline().parameters.validation_sql}"` で参照する（Script に直書きしない）。
> バリデーションエラーはパイプラインを Failed にしない。エラー行の有無は `customer_info_error` テーブル
> または `archive/error/*.csv` の中身（ヘッダのみ＝エラー無し）で確認する。

### テーブル（`apps/psql/.../create-tables.sql`）

参照ビュー（旧 `view_prd_table`）は廃止。Function/AKS は `customer_info_production` を直読する。

| テーブル | 用途 | 列（型方針） |
| --- | --- | --- |
| `customer_info_landing` | CSV 生ロード先（ランディング・未検証・全行） | 4列とも **`VARCHAR(255)` / NULL 可**。桁数超過・型違反・空も受け入れ、検証は SQL で行う |
| `customer_info_staging` | 検証 OK 行の入替バッファ（毎回 TRUNCATE 再投入し production へ UPSERT。rename しない） | production と同一の厳格スキーマ + インデックス + **NOT NULL**（LIKE 継承＋明示 SET NOT NULL） |
| `customer_info_production` | 本番（Function/AKS が直読） | `policy_no VARCHAR(10)` / `name_kana VARCHAR(50)` / `birth_ymd VARCHAR(8)` / `cellular_phone_no VARCHAR(15)`、全列 **NOT NULL** + `(name_kana, birth_ymd, cellular_phone_no)` 複合インデックス |
| `customer_info_error` | 検証 NG 行（`error_message` 付き） | データ4列・`error_message` とも **`VARCHAR(255)` / NULL 可**（NG 値をそのまま記録。message は理由コードのみ） |

> landing/error を `VARCHAR(255)`（寛大上限）にすることで、桁数超過値も Copy(Sink) でハード Fail せず
> landing に入り、SQL の桁数チェックで error 行に振り分けられる（§4-③ 参照）。255 超の異常値のみロード段階で弾く。
> ※ PostgreSQL の `VARCHAR(n)` は**バイトではなく文字数**。`name_kana VARCHAR(50)` = 全角カナ 50 文字。

---

## 2. 自動トリガーの仕組み

`azurerm_data_factory_trigger_blob_event.csv_uploaded`（`BlobEventsTrigger`）:

- `events = ["Microsoft.Storage.BlobCreated"]`
- `blob_path_begins_with = "/<upload_container>/blobs/input/"`、`blob_path_ends_with = ".csv"`
- `ignore_empty_blobs = true`、`activated = true`
- 起動時に `triggeredFileName = @triggerBody().fileName` をパイプラインへ渡す
  （Copy 元データセット `ds_src_csv` が `folderPath=input` + `firstRowAsHeader=true` + `fileName=@{...triggeredFileName}` で参照）。

**トリガーされる条件 = `input/` パス配下・拡張子 `.csv`・非空**。コンテナ直下や別パスに置くと起動しない。
同名 `input/ciupload39.csv` を毎回アップロードする運用で、過去版は Blob バージョニングで保持される。

### Event Grid RP の登録が必須
`BlobCreated` は **Event Grid** 経由。Hub サブスクリプションで `Microsoft.EventGrid` リソースプロバイダが
未登録だとイベントが流れず**トリガーされない**（パイプライン定義は正しくても発火しない）。

```bash
HUB_SUB=$(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)
az provider show -n Microsoft.EventGrid --subscription "$HUB_SUB" --query registrationState -o tsv
az provider register --namespace Microsoft.EventGrid --subscription "$HUB_SUB"   # 未登録時
```

---

## 3. 検証 + customer_info_production 入れ替え（Script Activity）

検証 SQL の流れ:

1. `TRUNCATE customer_info_staging; TRUNCATE customer_info_error;`
2. CTE `judged` で各行の `format_error`（必須/桁数/型の最初の該当理由）と `id_count`（同一 policy_no 出現数）を算出。
   - **データ変更 CTE** `promote_ok` で OK 行（`format_error IS NULL AND id_count = 1`）を `customer_info_staging` へ。
   - 本体 INSERT で NG 行（`format_error IS NOT NULL OR id_count > 1`）を `customer_info_error` へ
     （理由＝`COALESCE(format_error, 'policy_no duplicated')`）。CTE はスコープが1文のため両 INSERT を1文にまとめる。
3. トランザクション内で `customer_info_production` を `customer_info_staging` に同期（案11: UPSERT + DELETE）:
   `INSERT ... SELECT FROM customer_info_staging ON CONFLICT (policy_no) DO UPDATE SET ...`（新規=INSERT / 既存=UPDATE）
   → `DELETE FROM customer_info_production WHERE policy_no NOT IN (SELECT policy_no FROM customer_info_staging)`（消失行）。
   production は永続テーブル（drop/rename しない）のため **SELECT 権限・インデックスは恒久＝再 GRANT 不要**。
   `ON CONFLICT` は production の `PRIMARY KEY(policy_no)` を競合キーに使う。

### バリデーション規則（landing は VARCHAR(255) のため SQL 側で全チェック）

| 種別 | 項目 | 規則 | error_message 例 |
| --- | --- | --- | --- |
| 必須 | policy_no/name_kana/birth_ymd/cellular_phone_no | NULL/空でない。**空白のみも空扱い**（name_kana=全角スペース `^　*$`、他=半角スペース `^ *$`） | `policy_no required` 等 |
| 桁数 | policy_no≤10 / name_kana≤50 / birth_ymd=8 / cellular_phone_no≤15 | `char_length` | `policy_no too long (max 10)` / `name_kana too long (max 50)` / `cellular_phone_no too long (max 15)` 等 |
| 型/形式 | policy_no=半角英数字 `^[0-9A-Za-z]+$` / name_kana=全角カナ `^[ァ-ヾ]+　[ァ-ヾ]+$` / birth_ymd=`^[0-9]{8}$` **かつ実在日** / cellular_phone_no=半角数字 3-4-4 `^[0-9]{3}-[0-9]{4}-[0-9]{4}$` | 正規表現＋`to_date` round-trip | `name_kana must be zenkaku katakana …` / `birth_ymd is not a valid calendar date` 等 |
| 重複 | landing バッチ内で policy_no 一意（`count(*) OVER (PARTITION BY policy_no)`） | 重複は全行 NG | `policy_no duplicated` |

> 補足: `birth_ymd` は形式 `^[0-9]{8}$`（8桁）とは分離して**実在日**を検証。実在日セクションで月 1-12/日 1-31 を
> `substring` でレンジガード後、**`to_date` の round-trip**（`to_char(to_date(b,'YYYYMMDD'),'YYYYMMDD') = b`）で確認する。
> レンジガードは `to_date` が月>12・日0 等で例外を投げ Script を落とすのを防ぐためで、削除しないこと。
> `20260230`/`20261301` は NG、閏年 `20240229` は OK。
> cellular_phone_no は半角数字 **3-4-4 固定**（旧 `char_length≤15` は撤去）。policy_no は **半角英数字**を必須化。
> policy_no 重複は **reject-all**（重複 policy_no を持つ行は全て error。production には入れない）。

---

## 4. 落とし穴（今回踏んだもの）

実際にこのパイプラインを動かして発見した点。いずれも修正済み。

### ① （旧構成）`DROP TABLE prd_table` が view 依存で失敗（`2BP01`）
> 参照ビュー（旧 `view_prd_table`）を廃止したため**現在は発生しない**。以下は view 併存時の記録。
> view が本番テーブルに依存するため `DROP TABLE` が拒否され、`DROP VIEW` を先に実行する必要があった。
> 詳細: [troubleshooting.md](./troubleshooting.md) §12。

### ② rename で SELECT 権限が消える（案11 で解消）
旧構成（DROP/RENAME swap）では `customer_info_staging`→`customer_info_production` の rename が権限を引き継がず
（`LIKE ... INCLUDING ALL` も privileges 非対象）、入替後に `ci00-func`/`ci00-jumpbox` の SELECT が失われ permission denied になった。
旧対処はトランザクション末尾での再 `GRANT`（冪等）。
→ **案11**（production を永続テーブル化し UPSERT+DELETE で同期）に変更し rename 自体を廃止。
  create-tables.sql の初回 `GRANT` が恒久化され、**validation.sql での再 GRANT は不要**になった。

### ③ （解消済み）列長超過が pipeline ごと Failed していた
旧構成では `customer_info_landing` が厳格型（`VARCHAR(10/100/8/15)`）だったため、超過値（id 11 文字等）は
`InputCSV` の Sink で `22001 value too long` となり、**検証に到達せずロード段階で失敗**していた。
→ **landing を `VARCHAR(255)` に変更**し、超過値も landing に入るようにした。SQL の桁数チェック
（`char_length(id) > 10` 等）で `id too long (max 10)` として `customer_info_error` に振り分けられ、
**pipeline はハード Fail しない**。error も `VARCHAR(255)` なので超過値をそのまま記録できる
（255 超の異常値のみロード段階で 22001）。

### ④ 空欄（NULL）行を取りこぼさない（3 値論理）
CSV の空フィールドは Copy で **NULL**（または空文字）としてロードされる。素朴に
`WHERE NOT(id ~ regex AND …)` で振り分けると、NULL を含む行は `NOT(NULL AND …) = NULL` で
**両 INSERT から漏れて黙って消える**恐れがある。
→ 現行の検証 SQL は **CASE の先頭で `id IS NULL OR id = ''` を明示判定**（'... required'）し、
OK/NG を `format_error IS NULL` か否かの**厳密な補集合**で振り分けるため、NULL/空行も確実に error へ入る。
詳細: [troubleshooting.md](./troubleshooting.md) §13。

---

## 5. 動作確認・デバッグ手順

「動いていない」と感じたら、**トリガー発火**と**パイプライン成否**と**各 Activity**を切り分ける。

```bash
ADF=$(terraform -chdir=terraform/envs/hub-subscription output -raw data_factory_name)
HUB_RG=$(terraform -chdir=terraform/envs/hub-subscription output -raw resource_group_name)
SUB=$(terraform -chdir=terraform/envs/hub-subscription output -raw subscription_id)
AFTER=2026-01-01T00:00:00Z; BEFORE=2099-01-01T00:00:00Z

# (1) トリガーが発火したか / 起動しているか
az datafactory trigger show -g "$HUB_RG" --factory-name "$ADF" -n trg_csv_uploaded \
  --subscription "$SUB" --query "properties.runtimeState" -o tsv     # Started であること
az datafactory trigger-run query-by-factory -g "$HUB_RG" --factory-name "$ADF" --subscription "$SUB" \
  --last-updated-after "$AFTER" --last-updated-before "$BEFORE" \
  --query "value[].{trigger:triggerName,status:status,time:triggerRunTimestamp}" -o table

# (2) パイプライン成否（Failed の理由は message に出る）
az datafactory pipeline-run query-by-factory -g "$HUB_RG" --factory-name "$ADF" --subscription "$SUB" \
  --last-updated-after "$AFTER" --last-updated-before "$BEFORE" \
  --query "value[].{pipeline:pipelineName,status:status,run:runId,msg:message}" -o json

# (3) どの Activity で落ちたか（4 アクティビティの成否一覧）
RID=$(az datafactory pipeline-run query-by-factory -g "$HUB_RG" --factory-name "$ADF" --subscription "$SUB" \
  --last-updated-after "$AFTER" --last-updated-before "$BEFORE" --query "sort_by(value,&runStart)[-1].runId" -o tsv)
az datafactory activity-run query-by-pipeline-run -g "$HUB_RG" --factory-name "$ADF" --subscription "$SUB" \
  --run-id "$RID" --last-updated-after "$AFTER" --last-updated-before "$BEFORE" \
  --query "value[].{activity:activityName,status:status}" -o table
# error 件数は customer_info_error テーブル（または archive/error/*.csv の中身）で確認する
```

ポイント:
- **トリガー Succeeded ≠ パイプライン Succeeded**。トリガー run はパイプライン起動の成否のみ。中身は pipeline-run / activity-run を見る。
- **コールドスタート**: ADF Managed VNet の統合ランタイムは初回起動に数分かかる。`InProgress` が続いても異常ではない。
- **pipeline-run が空**＝まだ発火していない可能性。アップロードの**直後**は記録に出るまで時間差がある。

### トリガー無しで手動再実行（SQL 修正後の検証など）
Copy 元が `triggeredFileName` パラメータを参照するため、ファイル名を渡す。
SQL を直した場合は **Hub の terraform apply でパイプライン定義を再生成**してから実行する。

```bash
terraform -chdir=terraform/envs/hub-subscription apply -target='azurerm_data_factory_pipeline.csv_ingest[0]'
az datafactory pipeline create-run -g "$HUB_RG" --factory-name "$ADF" --subscription "$SUB" \
  --name pl_csv_ingest --parameters '{"triggeredFileName":"ciupload39.csv"}'
```

---

## 6. 失敗ケース CSV の作り方

`generate_invalid_csv.py` が **意図がファイル名で分かる**違反 CSV を `./csv` 配下に種別ごとに生成する
（必須/桁数/型/id重複。landing が VARCHAR(255) なので**桁数超過も含め全て Succeeded で error 行**になる。
各ファイルは正常 `--valid` 行 + 違反 `--per-category` 行）。

```bash
python apps/storage/script-for-generating-sample-csv/generate_invalid_csv.py \
  --valid 5 --per-category 2 --out-dir ./csv
```

| ファイル | 期待結果（`--valid 5 --per-category 2`。すべて Succeeded） |
| --- | --- |
| `invalid_id_empty.csv` / `invalid_name_hiragana.csv` / `invalid_birthdate_7digit.csv` / `invalid_phone_nodash.csv` / `invalid_id_overlength.csv` / `invalid_name_overlength.csv` | `customer_info_error`=2（該当理由）/ `customer_info_production`=5 |
| `invalid_id_duplicate.csv` | `customer_info_error`=**4**（`id duplicated`）/ `customer_info_production`=5 |
| `invalid_mixed.csv` | `customer_info_error`=**16**（6種×2 + 重複2組×2行）/ `customer_info_production`=5 |

アップロードは `upload-csv-to-blob.sh` でワンコマンド（規定名 `input/ciupload39.csv` へ同名上書き、
過去版は Blob バージョニングで保持、投入履歴は `csv/upload-manifest.tsv` に記録）:

```bash
bash apps/storage/script-for-generating-sample-csv/upload-csv-to-blob.sh ./csv/invalid_mixed.csv
```

実行時は `ArchiveError` も毎回走り、NG 行 CSV は `ciarchive39container/archive/error/error_*.csv` に出力される
（エラーが無い回はヘッダのみの空 CSV）。

---

## 7. 検証結果のアーカイブ（Success / Error CSV 出力）

**目的**: `ValidateData` の結果を、後続の確認・監査用に Blob アーカイブへ CSV で残す。
取込結果（`customer_info_production`）と検証 NG 行（`customer_info_error`）の両方を出力する。

**仕組み**: §1 のアクティビティ表 3〜4 のとおり。`ValidateData` の `Succeeded` 後に
`ArchiveSuccess` と `ArchiveError` を**並列・無条件**で実行する。

- `ArchiveSuccess`: `customer_info_production` → `ciarchive39container/archive/success/success_*.csv`
- `ArchiveError`: `customer_info_error` → `ciarchive39container/archive/error/error_*.csv`
  - **エラー行が無い回も実行される**ため、ヘッダのみ（データ 0 行）の CSV が出力される。

> **パイプラインは常に Succeeded**。バリデーションエラーは Activity 失敗として現れない（意図失敗の仕組みは廃止）。
> エラー行の有無は `customer_info_error` テーブル、または `archive/error/*.csv` の中身（ヘッダのみ＝エラー無し）で確認する。

> 補足: 以前はバリデーションエラーを `FailOnValidationError`（Fail Activity）の意図失敗で
> `ActivityFailedRuns` メトリックに立て、OpsRamp 等でアラートする構成だったが、見通し簡素化のため**廃止**した。
> メトリック/ログによるアラートが必要なら、別途 `customer_info_error` の行数監視や診断ログ側で実装する。

---

## 8. パイプライン・パラメータの意味と妥当性

`files/adf_pipeline/customer_info_registration/pipeline.json` 各アクティビティのパラメータ一覧と、本ユースケース
（**トリガー1件＝CSV1ファイル、数千〜数万行規模、閉域 Blob→PostgreSQL**）における値の妥当性評価。

### 8.1 実行ポリシー（`policy`）

| パラメータ | 設定箇所 | 現在値 | 単位 | 意味 | 妥当性・コメント |
|---|---|---|---|---|---|
| `timeout` | 全アクティビティ | `0.00:30:00`（30分） | 時間（`D.HH:MM:SS`） | アクティビティ**1試行**の最大実行時間。超過で Timeout 失敗 | ✅ 100万行でも実処理は分オーダー（InputCSV ~1–8分 + Managed VNet IR コールドスタート ~1–4分、ValidateData 数分）。30分で実処理の約3–6×マージン。12h 既定より早期に失敗検知 |
| `retry` | 全アクティビティ | `1` | 回 | 失敗時に**アクティビティ全体を再実行**する回数（in-timeout のコネクション再試行ではない） | ✅ 一過性エラー（瞬断・スロットリング）を1回吸収。決定論的失敗（SQL/権限/スキーマ）は再試行しても同じなので即終了。ValidateData も `validation.sql` が landing から再構築する**冪等**設計のため再試行安全 |
| `retryIntervalInSeconds` | 全アクティビティ | `30` | 秒（範囲 30〜86400） | リトライ間隔 | ✅ 最小値。一過性エラーの回復待ちとして妥当 |

> **最悪実行時間の式**: `(retry+1) × timeout + retry × retryIntervalInSeconds`。
> 現行（retry=1 / timeout=30分 / interval=30秒）なら **最悪 ≈ 2×30分 + 30秒 ≈ 約60分／アクティビティ**（真にハングした場合）。
> 決定論的失敗なら数秒×2＋30秒で即終了。retry を上げるほど最悪時間が `timeout` 倍で増えるため、timeout とセットで考える。

### 8.2 取込 Copy: 読み取り側（InputCSV `source.storeSettings` = `AzureBlobStorageReadSettings`）

| パラメータ | 現在値 | 意味 | 妥当性・コメント |
|---|---|---|---|
| `recursive` | `false` | サブフォルダを再帰的に読むか | ✅ 妥当。トリガーが `triggeredFileName` で **単一ファイル**を `input/` 直下指定。再帰不要 |
| `enablePartitionDiscovery` | `false` | `key=value` 形式のパーティションフォルダを列に展開するか | ✅ 妥当。Hive 風パーティション構造はなくフラットな単一 CSV。`true` だと不要な列・誤解析の元 |

> 文字コード/区切り/ヘッダ等（`shift_jis` / `,` / `firstRowAsHeader` 等）は **Dataset `ds_src_csv` の type_properties** 側に定義。
> ここ（`formatSettings: DelimitedTextReadSettings`）は空で Dataset 設定を継承する。

### 8.3 取込 Copy: 書き込み側（InputCSV `sink` = `AzurePostgreSqlSink`）

| パラメータ | 現在値 | 単位 | 意味 | 妥当性・コメント |
|---|---|---|---|---|
| `preCopyScript` | `TRUNCATE TABLE customer_info_landing;` | — | Copy 前に流す SQL。landing を空にする | ✅ 妥当。landing は**ステージング用**。投入前 TRUNCATE で「同一ファイル再実行＝冪等」を担保。トリガーは1ファイル直列前提のため競合なし |
| `writeBatchSize` | `10000` | 行 | Copy が1回の書き込みでまとめて PostgreSQL へ送る**行数**（大=往復減で速いがメモリ大、小=往復増で遅いがメモリ小） | ✅ 妥当。**計算例**: 4列 narrow ≈ 80–150 B/行 ⇒ 1万行 ≈ **~1–1.5 MB/バッチ**、100万行で **100バッチ**。最大総量 ~100MB に対し**余裕が大きい**。本規模では値の感度は小さく 5,000〜100,000 のいずれでも実時間差はわずか。※ **`ValidateData`(Script) には非適用**（PG 内の集合 INSERT のため ADF はバッチ分割しない） |
| `enableStaging` | `false`（typeProperties 直下） | 真偽 | 中間 Blob ステージング（staged copy）を使うか | ✅ 妥当。Blob→PG の直接コピーで十分。ステージングは DWH 大量ロード向けで本ケースには不要 |
| `translator.mappings` | CSV ヘッダ→列名の明示マッピング | — | `顧客_番号→policy_no` 等、ヘッダ名ベースで対応付け | ✅ 妥当。列順非依存・全列 String 受け（landing は VARCHAR(255)）。型/長さの検証は §3 の Script 側に集約 |

### 8.4 アーカイブ Copy: 出力 CSV（ArchiveSuccess / ArchiveError `sink.formatSettings` = `DelimitedTextWriteSettings`）

| パラメータ | 現在値 | 意味 | 妥当性・コメント |
|---|---|---|---|
| `quoteAllText` | `true` | 全フィールドを引用符で囲む | ✅ 妥当。氏名等に区切り文字/改行/前後空白が混在しても壊れない。**安全側**。ファイルはやや大きくなるがアーカイブ用途では許容 |
| `fileExtension` | `.csv` | 出力ファイル拡張子 | ✅ 妥当。出力名は Dataset 側の式（`_success_`/`_error_` + タイムスタンプ）で生成 |

> ソース側（`AzurePostgreSqlSource.query`）は production / error テーブルから必要列を SELECT。`enablePartitionDiscovery` 等の
> Blob 読み取り設定は出力側には無関係。

### 8.5 依存・制御フロー

| パラメータ | 現在値 | 意味 | 妥当性・コメント |
|---|---|---|---|
| `dependsOn[].dependencyConditions` | `["Succeeded"]` | 先行アクティビティ成功時のみ実行 | ✅ 妥当。`InputCSV → ValidateData → (ArchiveSuccess / ArchiveError)` の直列・成功連鎖 |
| Script `type` | `NonQuery` | 結果セットを返さない SQL（DML/DDL） | ✅ 妥当。検証＋ production 入替は NonQuery。`Query` は SELECT 結果取得用で本処理には不要 |

### 8.6 設定の経緯・チューニング指針

- **timeout=30分 / retry=1 一律**に統一済み（旧: timeout=12h、ValidateData retry=0、Archive policy 未設定）。
  全アクティビティに `policy:{timeout:"0.00:30:00", retry:1, retryIntervalInSeconds:30}` を明示。
- さらに resilience を上げたい場合は retry を増やせるが、§8.1 の式どおり最悪時間が `timeout` 倍で伸びる
  （retry=3 なら最悪 ~4×30分=120分）。失敗検知の速さとのトレードオフで選ぶ。
- データが恒常的に 100万行を大きく超える、または取込スループットが想定より遅い場合は timeout を見直す。
  `writeBatchSize` は本規模では感度が小さいため据置（必要なら 50000 へ）。

### 8.7 実行時間の目安（アクティビティ別）

各アクティビティの **想定時間（通常 ~20万行）/ 実処理の最悪（~100万行）/ ポリシー上限（強制失敗まで）** の目安。
直列パスは `InputCSV → ValidateData → (ArchiveSuccess ∥ ArchiveError)`（Archive 2本は並列）。

| アクティビティ | 想定（~20万行） | 実処理の最悪（~100万行） | ポリシー上限 | 主因・備考 |
|---|---|---|---|---|
| InputCSV | ~2–3分 | ~12分 | ~60分 | **Managed VNet IR コールドスタート ~1–4分**が支配的。データ移動は ~2k–20k 行/秒 |
| ValidateData | ~0.5–1分 | ~2–3分 | ~60分 | IR は温まっている。100万行の正規表現検証＋UPSERT/DELETE 同期が主。PG SKU 依存 |
| ArchiveSuccess | ~1–2分 | ~3–4分 | ~60分 | production 全行を CSV 出力。ArchiveError と**並列** |
| ArchiveError | 数秒–~1分 | ~1–2分 | ~60分 | NG 行のみ（通常少量）。**並列** |
| **パイプライン合計** | **~4–6分** | **~17–20分** | **~3時間（≈181分）** | 合計＝直列パス（Archive は並列なので大きい方=Success を1本計上） |

- **想定/最悪は実処理ベースの見積り**（スループット・IR コールドスタートの仮定。実値は初回ランで要確認）。
- **ポリシー上限**は §8.1 の式 `(retry+1)×timeout + retry×interval = 2×30分+30秒 ≈ 60分` の積み上げ。
  全アクティビティが timeout までハングし続けた場合に ADF が強制失敗させるまでの理論上限で、通常は到達しない。
- IR コールドスタートはランの先頭（InputCSV）で1回。`time_to_live_min=0`（モジュール既定）のため毎ラン発生する。
  連続実行が多く短縮したい場合は IR の TTL を延ばす選択肢があるが、本ユースケース（低頻度・イベント駆動）では不要。

---

## 関連

- トラブルシュート（§12 view 依存 / §13 NULL・列長）: [troubleshooting.md](./troubleshooting.md)
- 認証・権限（ADF/Function/踏み台 の MI と PostgreSQL ロール）: [auth.md](./auth.md)
- ネットワーク・閉域化（Managed VNet / Managed PE / Storage・PG の PE）: [network.md](./network.md)
- 取込先テーブルのスキーマ: `apps/psql/sql-for-setting-up-database/create-tables.sql`
- Function API 仕様: [api-customer-search.md](./api-customer-search.md)
- ランタイムの流れ・失敗ケース手順: リポジトリ直下 `README.md`「動作の流れと確認方法（ランタイム）」
