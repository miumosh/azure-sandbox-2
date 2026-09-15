# 経路1: Storage に CSV を投入して結果を確認する

CSV を `ciupload39container/input/` に置く → `BlobCreated`（Event Grid）→ ADF `pl_csv_ingest` →
PostgreSQL、という取り込み経路を手で流して、**成功パターン**（`customer_info_production` に入る）と
**失敗パターン**（`customer_info_error` に理由付きで入る／ロード段階で Failed になる）を網羅確認する。

前提と共通の環境変数は [README.md](./README.md) を参照。

> **アップロードは手動で行う。** 本書は「どのファイルを・どこに・どの名前で置くか」と「その結果をどう確認するか」だけを扱う。
> アップロード操作そのもの（Storage Explorer / ポータル / `az` のいずれを使うか、SAS の取り回し等）は対象外。
>
> | 投入先 | 値 |
> | --- | --- |
> | Storage アカウント | `terraform -chdir=$HUB_TF output -raw storage_account_name` |
> | コンテナ | `terraform -chdir=$HUB_TF output -raw upload_container_name` |
> | Blob 名（規定名） | **`input/ciupload39.csv`**（毎回同名で上書き。過去版は Blob バージョニングで保持される） |
>
> 投入したファイルと日時は自動記録されないので、**実施者が控えておくこと**（ADF の run と突き合わせるのに要る）。

> **バリデーション違反ではパイプラインは Failed にならない。** 常に Succeeded で、違反行は
> `customer_info_error` に振り分けられる。Failed になるのはロード段階のエラー（下記 C の L-06）だけ。

---

## 0. 前提データを投入する

経路2（Function API）が検索する既知データを production に入れておく。経路2 を実施しない場合も、
「正常系がひととおり通ること」の確認を兼ねてここから始めるとよい。

`test/data/csv/scenario_known_person.csv` を **`input/ciupload39.csv` として手動アップロードする**（6 行）。

生成済みのものが `test/data/csv/` に入っているので、通常は再生成不要。作り直す場合は次を実行する
（乱数を使わないため内容は毎回同一。生成と同時に期待値も表示される）。

```bash
python3 test/scripts/csv/generate_scenario_csv.py   # 出力先の既定は test/data/csv
```

`scenario_known_person.csv` の中身（経路2 の検索キーはこの値を使う）:

| policy_no | name_kana | birth_ymd | cellular_phone_no | 用途 |
| --- | --- | --- | --- | --- |
| `0000000001` / `0000000002` / `0000000003` | `タナカ　タロウ` | `19900101` | `090-1111-2222` | 同一人物が複数 policy_no を持つ（MATCH 3 件） |
| `0000000004` | `スズキ　ハナコ` | `19851215` | `080-3333-4444` | MATCH 1 件 |
| `0000000005` | `サトウ　イチロウ` | `19701010` | `070-5555-6666` | 予備 |
| `AB12345678` | `アアア…　イイイ…`（ちょうど 50 文字） | `20240229` | `090-0000-0001` | 境界値（10 桁英数 / 50 文字 / 閏日） |

---

## 1. 1 ファイル分のテスト手順

```bash
# (1) 投入前に期待値を確定する（validation.sql を同一の評価順で再現）
python3 test/scripts/csv/simulate_validation.py test/data/csv/scenario_charset.csv

# (2) 投入 … test/data/csv/scenario_charset.csv を規定名 input/ciupload39.csv として**手動アップロード**
#     （同名上書き。過去版は Blob バージョニングで保持される）

# (3) パイプラインの成否を確認（数分かかる。Managed VNet IR のコールドスタート込みで ~4-6 分）
az datafactory pipeline-run query-by-factory -g "$HUB_RG" --factory-name "$ADF" --subscription "$HUB_SUB" \
  --last-updated-after "$AFTER" --last-updated-before "$BEFORE" \
  --query "sort_by(value,&runStart)[-1].{pipeline:pipelineName,status:status,run:runId,msg:message}" -o json

# (4) 件数を rowsRead で突合（InputCSV=入力全行 / ArchiveSuccess=production / ArchiveError=error）
RID=$(az datafactory pipeline-run query-by-factory -g "$HUB_RG" --factory-name "$ADF" --subscription "$HUB_SUB" \
  --last-updated-after "$AFTER" --last-updated-before "$BEFORE" --query "sort_by(value,&runStart)[-1].runId" -o tsv)
az datafactory activity-run query-by-pipeline-run -g "$HUB_RG" --factory-name "$ADF" --subscription "$HUB_SUB" \
  --run-id "$RID" --last-updated-after "$AFTER" --last-updated-before "$BEFORE" \
  --query "value[].{activity:activityName,status:status,rowsRead:output.rowsRead,rowsCopied:output.rowsCopied}" -o table
```

**判定**: (3) が `Succeeded` かつ (4) の `rowsRead` が (1) の予測と一致すれば OK。

理由（`error_message`）までライブで確証したいときだけ、踏み台 VM から `psql` で見る（[../README.md](../README.md) 手順 4 のパスワードレス接続）:

```bash
# 踏み台 VM 上
psql "host=$PSQL_FQDN port=5432 dbname=appdb user=ci00-jumpbox sslmode=require" -c "
  SELECT error_message, count(*) FROM customer_info_error GROUP BY error_message ORDER BY 2 DESC;
  SELECT count(*) AS production FROM customer_info_production;"
```

全ファイルを順に流す場合は、次の順で**1 ファイルずつ手動アップロード**する（**必ず直列**。前の run が
Succeeded になったのを (3) で確認してから次を上げる）:

```
scenario_known_person → boundary_ok → blank_only → length → charset → calendar → duplicate
```

---

## 2. パターン一覧

### A. ファイル単位の期待値（`generate_scenario_csv.py` が生成）

`simulate_validation.py` の出力と一致することを確認済み（ローカル再現）。`production` は
**そのファイルの valid 行数**になる（毎回 UPSERT + DELETE で同期されるため、前回の内容は残らない）。

| ファイル | 観点 | 入力行 | 期待 production | 期待 error（内訳） | pipeline |
| --- | --- | --- | --- | --- | --- |
| `scenario_known_person.csv` | 経路2 の前提データ / 同一人物の複数 policy_no | 6 | **6** | 0 | Succeeded |
| `scenario_boundary_ok.csv` | 境界値だが全行合格 | 5 | **5** | 0 | Succeeded |
| `scenario_blank_only.csv` | 必須（空文字・空白のみ） | 9 | **1** | **8**（policy_no 2 / name_kana 2 / birth_ymd 2 / cellular_phone_no 2 の `... required`） | Succeeded |
| `scenario_length.csv` | 桁数超過 | 6 | **1** | **5**（`policy_no too long` 1 / `name_kana too long` 1 / `birth_ymd must be 8 digits` 2 / `cellular_phone_no too long` 1） | Succeeded |
| `scenario_charset.csv` | 文字種・形式 | 14 | **1** | **13**（`name_kana must be zenkaku katakana …` 5 / `cellular_phone_no must be XXX-XXXX-XXXX` 5 / `policy_no must be half-width alphanumeric` 2 / `birth_ymd must be 8-digit YYYYMMDD` 1） | Succeeded |
| `scenario_calendar.csv` | 実在日 | 10 | **3** | **7**（すべて `birth_ymd is not a valid calendar date`） | Succeeded |
| `scenario_duplicate.csv` | policy_no 重複 | 8 | **1** | **7**（`policy_no duplicated` 5 / `policy_no required` 2） | Succeeded |
| `scenario_header_only.csv` | データ 0 行 | 0 | **0** | 0 | Succeeded（production が**全削除**される） |
| `scenario_loadfail_over255.csv` | 255 文字超 | 2 | — | — | **Failed**（InputCSV が `22001`）※未実測 |
| `scenario_utf8_encoding.csv` | 規定外エンコーディング | 2 | ※未実測 | ※未実測 | ※未実測 |
| `scenario_crlf.csv` | 規定外改行コード | 2 | ※未実測 | ※未実測 | ※未実測 |
| `scenario_bad_header.csv` | ヘッダ名不一致 | 2 | ※未実測 | ※未実測 | ※未実測 |

> 量産版（正常 5 行 + 違反 2 行 × 8 ファイル）が要るときは既存の `generate_invalid_csv.py` を使う。
> 期待値と過去の実測結果は [../docs/test.md](../docs/test.md) にある。

### B. 行レベルのパターン（`validation.sql` の判定）

CASE は **必須 → 桁数 → 文字種/形式 → 実在日** の順に評価され、**最初に該当した理由だけ**が付く。
`policy_no` 重複はこれらを通過した後に判定される。

#### B-1. 合格する（`customer_info_production` に入る）

| # | 観点 | 入力例 | 収録ファイル |
| --- | --- | --- | --- |
| OK-01 | policy_no 最短（1 文字） | `1` | `scenario_boundary_ok.csv` |
| OK-02 | policy_no 上限（10 文字）・英数字混在 | `0123456789` / `AB12345678` / `Zz09` | `scenario_boundary_ok.csv` |
| OK-03 | name_kana 上限（ちょうど 50 文字） | `アア…　イイ…` | `scenario_boundary_ok.csv` |
| OK-04 | name_kana 最短（姓 1 + 全角スペース + 名 1） | `ア　イ` | `scenario_boundary_ok.csv` |
| OK-05 | name_kana に長音・繰返し記号・ヴ（`[ァ-ヾ]` の範囲内） | `アー　イヽ` / `ヴァヶ　ヲンヾ` | `scenario_boundary_ok.csv` |
| OK-06 | 閏年 2/29 | `20240229` / `20000229`（400 年閏） | `scenario_boundary_ok.csv` / `scenario_calendar.csv` |
| OK-07 | 月末日 | `20260430` / `20261231` | `scenario_boundary_ok.csv` / `scenario_calendar.csv` |
| OK-08 | 電話の下限・上限値 | `000-0000-0000` / `999-9999-9999` | `scenario_boundary_ok.csv` |
| OK-09 | **同一人物が複数 policy_no を持つ**（氏名・生年月日・電話が同じ） | 3 行が同じ 3 項目・policy_no だけ別 | `scenario_known_person.csv` |

> OK-09 が重複扱いにならないのが重要。重複判定は **`policy_no` のみ**を見る（`partition by policy_no`）。

#### B-2. 必須違反 → `... required`

| # | 項目 | 入力 | 期待 `error_message` | 収録ファイル |
| --- | --- | --- | --- | --- |
| V-01 | policy_no | 空文字 | `policy_no required` | `scenario_blank_only.csv` |
| V-02 | policy_no | 半角スペースのみ | `policy_no required` | 〃 |
| V-03 | name_kana | 空文字 | `name_kana required` | 〃 |
| V-04 | name_kana | **全角スペース**のみ | `name_kana required` | 〃 |
| V-05 | birth_ymd | 空文字 | `birth_ymd required` | 〃 |
| V-06 | birth_ymd | 半角スペースのみ | `birth_ymd required` | 〃 |
| V-07 | cellular_phone_no | 空文字 | `cellular_phone_no required` | 〃 |
| V-08 | cellular_phone_no | 半角スペースのみ | `cellular_phone_no required` | 〃 |

> 空白のみの判定は項目で正規表現が違う（`name_kana` は全角スペース `^　*$`、他は半角スペース `^ *$`）。
> `name_kana` に半角スペースだけを入れた場合は required にならず、文字種違反（V-16 系）になる。

#### B-3. 桁数違反 → `... too long` / `... must be 8 digits`

| # | 項目 | 入力 | 期待 `error_message` | 収録ファイル |
| --- | --- | --- | --- | --- |
| V-09 | policy_no | 11 文字 | `policy_no too long (max 10)` | `scenario_length.csv` |
| V-10 | name_kana | 51 文字 | `name_kana too long (max 50)` | 〃 |
| V-11 | birth_ymd | 7 桁 | `birth_ymd must be 8 digits` | 〃 |
| V-12 | birth_ymd | 9 桁 | `birth_ymd must be 8 digits` | 〃 |
| V-13 | cellular_phone_no | 16 文字以上（例 17 文字） | `cellular_phone_no too long (max 15)` | 〃 |

> `customer_info_landing` は 4 列とも `VARCHAR(255)`（寛大上限）なので、桁数超過値も**ロードには成功**し、
> SQL の桁数チェックで error に振り分けられる（pipeline は Succeeded のまま）。

#### B-4. 文字種・形式違反 → `... must be ...`

| # | 項目 | 入力 | 期待 `error_message` | 収録ファイル |
| --- | --- | --- | --- | --- |
| V-14 | policy_no | 全角数字 `０１２３４５` | `policy_no must be half-width alphanumeric` | `scenario_charset.csv` |
| V-15 | policy_no | 記号入り `ABC-12345` | `policy_no must be half-width alphanumeric` | 〃 |
| V-16 | name_kana | ひらがな `たなか　たろう` | `name_kana must be zenkaku katakana in sei<full-width space>mei form` | 〃 |
| V-17 | name_kana | 漢字 `田中　太郎` | 〃 | 〃 |
| V-18 | name_kana | 半角カナ `ﾀﾅｶ　ﾀﾛｳ` | 〃 | 〃 |
| V-19 | name_kana | 姓名の区切り無し `タナカタロウ` | 〃 | 〃 |
| V-20 | name_kana | 区切りが**半角**スペース `タナカ タロウ` | 〃 | 〃 |
| V-21 | birth_ymd | 8 文字だが非数字 `1990/1/1` | `birth_ymd must be 8-digit YYYYMMDD` | 〃 |
| V-22 | cellular_phone_no | ハイフン無し `09011112222` | `cellular_phone_no must be XXX-XXXX-XXXX` | 〃 |
| V-23 | cellular_phone_no | 3-4-3 `090-1111-222` | 〃 | 〃 |
| V-24 | cellular_phone_no | 2-4-4 `03-1111-2222` | 〃 | 〃 |
| V-25 | cellular_phone_no | 全角 `０９０ー１１１１ー２２２２` | 〃 | 〃 |
| V-26 | cellular_phone_no | 15 文字だが 4-4-4 `0900-1111-2222` | 〃 | 〃 |

> 電話は **3-4-4 固定**（`^[0-9]{3}-[0-9]{4}-[0-9]{4}$`）。市外局番が 2 桁・4 桁の実在番号も NG になる。
> Function 側の検証はこれより緩い（[02-function-api.md](./02-function-api.md) の F-B06）ので、**層によって通る/通らないが違う**。

#### B-5. 実在日違反 → `birth_ymd is not a valid calendar date`

いずれも 8 桁数字なので形式チェックは通過し、実在日チェックで落ちる。

| # | 入力 | 内容 | 収録ファイル |
| --- | --- | --- | --- |
| V-27 | `20260230` | 2 月 30 日 | `scenario_calendar.csv` |
| V-28 | `20260431` | 4 月 31 日 | 〃 |
| V-29 | `20260631` | 6 月 31 日 | 〃 |
| V-30 | `20261301` | 13 月 | 〃 |
| V-31 | `20260001` | 0 月 | 〃 |
| V-32 | `20260100` | 0 日 | 〃 |
| V-33 | `19000229` | 100 で割り切れる年は非閏（1900/2/29 は存在しない） | 〃 |

#### B-6. 重複 → `policy_no duplicated`

| # | 入力 | 期待 | 収録ファイル |
| --- | --- | --- | --- |
| V-34 | 同一 policy_no が 2 行 | **2 行とも** error（reject-all。production には入れない） | `scenario_duplicate.csv` |
| V-35 | 同一 policy_no が 3 行 | **3 行とも** error | 〃 |
| V-36 | 空の policy_no が複数行 | `policy_no required` が優先され、`duplicated` にはならない | 〃 |

### C. ファイル・投入レベルのパターン

| # | パターン | 期待 | 実測 |
| --- | --- | --- | --- |
| L-01 | 規定名 `input/ciupload39.csv` で投入 | トリガー発火 → 取り込み | ✅ 実測済 |
| L-02 | `input/` 配下だが別名（例 `input/foo.csv`） | 発火する（条件は「`input/` 配下・`.csv`・非空」。ファイル名は `triggeredFileName` で渡る） | ※未実測 |
| L-03 | 拡張子が `.csv` でない（例 `input/data.txt`） | **発火しない**（`blob_path_ends_with = ".csv"`） | ※未実測 |
| L-04 | `input/` 以外（コンテナ直下・別フォルダ） | **発火しない**（`blob_path_begins_with = "/<container>/blobs/input/"`） | ※未実測 |
| L-05 | 0 バイトのファイル | **発火しない**（`ignore_empty_blobs = true`） | ※未実測 |
| L-06 | 255 文字を超える値を含む（`scenario_loadfail_over255.csv`） | **InputCSV が `22001 value too long` で Failed**（唯一の pipeline 失敗系。検証 SQL に到達しない） | ※未実測 |
| L-07 | ヘッダのみ・データ 0 行（`scenario_header_only.csv`） | Succeeded。staging が空 → **`customer_info_production` が全削除**される | ※未実測 |
| L-08 | 前回より行数が少ない CSV | Succeeded。staging に無い policy_no は **DELETE** され production が縮む | ✅ 実測済（異常系 CSV 投入時に production が valid 行数まで縮む） |
| L-09 | 同じファイルを再投入 | Succeeded。`preCopyScript` の TRUNCATE + UPSERT により**冪等**（同じ結果） | ※未実測（`valid.csv` を複数回投入した実績はあり） |
| L-10 | 規定外エンコーディング（UTF-8。`scenario_utf8_encoding.csv`） | Dataset は `shift_jis` 固定のため文字化けし、ヘッダ名も一致しなくなる → 取り込み失敗または全行 error と推測 | ※未実測 |
| L-11 | 規定外改行コード（CRLF。`scenario_crlf.csv`） | 行末に `\r` が残ると最終列（電話）が形式違反になる可能性 | ※未実測 |
| L-12 | ヘッダ名が規定と違う（`scenario_bad_header.csv`） | ヘッダ名マッピングが一致せず、列が NULL → 全行 `... required` になると推測 | ※未実測 |
| L-13 | 短時間に複数ファイルを投入 | `concurrency = 1` で**キューイングされ直列実行**。ただし production は最後の run の内容になる | ※未実測 |
| L-14 | Event Grid RP (`Microsoft.EventGrid`) 未登録の状態で投入 | トリガー自体が発火しない（パイプライン定義が正しくても動かない） | ※必須条件として記載あり（[../docs/pipeline.md](../docs/pipeline.md) §2） |

> 「※未実測」は `validation.sql` / トリガー定義から導いた**設計上の期待値**。実機で確認したら実測欄を更新する。

---

## 3. トリガー条件のテスト（L-02〜L-05）

トリガー条件そのものを試すケースでは、**規定名ではない Blob 名**で手動アップロードする。
アップロードするファイルの中身は何でもよい（`scenario_known_person.csv` を使えばよい）。

| # | 手動アップロード時に指定する Blob 名 | ファイル | 期待 |
| --- | --- | --- | --- |
| L-02 | `input/foo.csv` | `test/data/csv/scenario_known_person.csv` | 発火**する** |
| L-03 | `input/ciupload39.txt` | 同上 | 発火しない（拡張子が `.csv` でない） |
| L-04 | `ciupload39.csv`（コンテナ直下） | 同上 | 発火しない（`input/` 配下でない） |
| L-05 | `input/empty.csv` | 0 バイトのファイル | 発火しない（`ignore_empty_blobs = true`） |

発火の有無は trigger-run / pipeline-run が増えたかどうかで判定する。

```bash
# 発火しなかったこと = 新しい trigger-run / pipeline-run が増えていないことで判定する
az datafactory trigger-run query-by-factory -g "$HUB_RG" --factory-name "$ADF" --subscription "$HUB_SUB" \
  --last-updated-after "$AFTER" --last-updated-before "$BEFORE" \
  --query "value[].{trigger:triggerName,status:status,time:triggerRunTimestamp}" -o table
```

---

## 4. 後片付け

異常系 CSV を流したままだと production がテスト内容のままになる。次のどちらかを**規定名で手動再投入**して戻す。

- 経路2 を続ける場合（既知データ 6 行に戻す）: `test/data/csv/scenario_known_person.csv`
- 本番相当に戻す場合: `test/data/csv/valid.csv`（現物は 1,000 行。10 万件に増やすなら下記で再生成する）

```bash
python3 test/scripts/csv/generate_sample_csv.py --rows 100000   # 出力先の既定は test/data/csv
```
