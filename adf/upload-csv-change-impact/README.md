# ds_src_csv のエンコード / 改行コード変更の影響検証

対象: [`ds_src_csv.json`](../../test/storage-adf-psql-function-aks-relation/terraform/envs/hub-subscription/files/adf_pipeline/customer_info_registration/datasets/ds_src_csv.json)

| 項目 | 変更前 | 変更後 |
|------|--------|--------|
| `encodingName` | `shift_jis` | `UTF-8` (入力ファイルは BOM 付き) |
| `rowDelimiter` | `\n` (LF) | `\r\n` (CRLF) |

本来の流れは「CSV をアップロード → ADF (Copy → Script) → PostgreSQL」。ここでは Azure を使わず、
**Copy で landing に取り込まれるところまでを Python で模擬し、その後の Script は本番の `validation.sql` を
ローカル PostgreSQL でそのまま実行**して、success / error の出力を確認する。

## 構成

| パス | 内容 |
|------|------|
| `datasets/ds_src_csv.before.json` | 変更前の Dataset 定義 (本番ファイルのコピー) |
| `datasets/ds_src_csv.after.json` | 変更後の Dataset 定義 (`encodingName` / `rowDelimiter` だけを変更) |
| `fixtures/base.csv` | 入力 CSV の論理内容 (OK 3 行 / NG 2 行、うち 1 行はクォート付き) |
| `make_inputs.py` | `base.csv` からエンコード × 改行コードの組合せ 5 種類を `inputs/` に生成する |
| `verify.py` | Dataset 2 種 × 入力 5 種 = 10 ケースを実行し、`out/<case>/` に結果を出力する |
| `docker-compose.yml` | ローカル PostgreSQL 16 |
| `run.sh` | 上記をまとめて実行する |
| `azure/` | 変更後の `ds_src_csv` を持つ ADF を実機に構築して検証する Terraform 一式 ([README](./azure/README.md)) |

次のファイルは**コピーせず本番の定義を直接読む**ため、本番側を直せば検証にもそのまま反映される。

- `pipeline.json` … InputCSV の translator マッピング (CSV ヘッダ名 → landing の列)
- `queries/validation.sql` … ValidateData (Script) の SQL
- `create-tables.sql` … テーブル定義 (末尾にある AAD ロールへの GRANT は除く)

## 使い方

```bash
./run.sh                      # 入力生成 → DB 起動 → 全ケース実行
./run.sh --bom keep           # 前提を変えて実行する (後述)
docker compose down           # 後片付け
```

終了コードは、本命の比較 `before__sjis_lf` == `after__utf8bom_crlf` (success / error の中身が完全一致) が
PASS なら 0、FAIL なら 1。

### 出力 (`out/`)

| ファイル | 内容 |
|----------|------|
| `out/<case>/success.csv` | Script 実行後の `customer_info_production` (ArchiveSuccess 相当) |
| `out/<case>/error.csv` | `customer_info_error` (ArchiveError 相当。`error_message` 付き) |
| `out/<case>/copy_failed.txt` | Copy 段階で失敗した理由。このケースでは Script は実行しない |
| `out/summary.json` | 全ケースの結果 |

`<case>` は `<Dataset>__<入力>` (例: `after__utf8bom_crlf`)。
ケースごとに production を TRUNCATE しているため、前のケースの結果は次のケースに持ち越さない。

## 結果 (既定の前提: BOM 除去 / マッピング元の列が無ければ失敗)

| 入力 \ Dataset | before (shift_jis, LF) | after (UTF-8, CRLF) |
|---|---|---|
| `sjis_lf` (現行フォーマット) | **OK** success 3 / error 2 | COPY_FAILED (文字化け + 全体が 1 行になる) |
| `sjis_crlf` | COPY_FAILED (ヘッダ末尾に `\r` が残る) | COPY_FAILED (文字化け) |
| `utf8bom_crlf` (新フォーマット) | COPY_FAILED (文字化け) | **OK** success 3 / error 2 |
| `utf8bom_lf` | COPY_FAILED (文字化け) | COPY_FAILED (全体が 1 行になる) |
| `utf8_crlf` (BOM なし) | COPY_FAILED (文字化け) | **OK** success 3 / error 2 |

- 新フォーマット (`after__utf8bom_crlf`) の success / error は、現行 (`before__sjis_lf`) と**完全に一致**する。
- 変更後は **Shift_JIS のファイルも LF のファイルも取り込めない**。どちらもヘッダ名がマッピングと一致しないため、
  行単位の error にはならず **パイプライン全体が InputCSV で失敗**する (production は更新されない)。
  切替時に旧フォーマットのファイルが混ざらないよう、アップロードする側との切替タイミングの調整が必要。
- BOM なしの UTF-8 は、変更後の設定でも取り込める。

## 実機 ADF での実測結果 (2026-09-29)

[`azure/`](./azure/README.md) で構築した ADF に `inputs/*.csv` を流し、上の表の **10 ケースすべてがローカル模擬と一致**した。

- `after__utf8bom_crlf` (新フォーマット × 変更後の設定) の success / error は、`before__sjis_lf` (現行) と行単位で完全一致。
- **BOM 付き UTF-8 は、ADF が BOM を除去して読み込む** (ヘッダ 1 列目が `顧客_番号` として一致した)。
- 取込失敗のケースは、すべて InputCSV が `MappingColumnNameNotFoundInSourceFile` で失敗した
  (例: `Column '顧客_番号' specified in column mapping cannot be found in 'sjis_lf.csv' source file.`)。
  見つからないと報告された列名も模擬と一致 (Shift_JIS 誤読は `顧客_番号`、行区切り不一致は `顧客_電話番号`)。
- 参考: ArchiveSuccess / ArchiveError の出力 CSV (`encodingName: utf-8`) には BOM が付く。今回の変更とは無関係 (出力側の Dataset は変更していない)。

生の結果は `azure/out-azure/` にある。

## BOM の扱いに関する公開情報 (2026-09-29 時点で調査)

**Copy activity が「読み込み時に BOM を除去する」と明記した公式ドキュメントは見つからなかった。**
BOM 付きでも問題ないという判断は、上記の実測と、以下の間接的な情報に基づく。

| 情報源 | 内容 | 本件への示唆 |
|--------|------|--------------|
| [Delimited text format (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/data-factory/format-delimited-text) の `encodingName` | 許容値に `"UTF-8"` と `"UTF-8 without BOM"` がある。注記は「**Note mapping data flow doesn't support UTF-8 encoding with Byte Order Mark (BOM).**」 | BOM 付き UTF-8 が非対応と明記されているのは **Mapping Data Flow だけ**。本パイプラインは Copy activity なので対象外。将来 Data Flow に置き換える場合は BOM 付きが使えなくなる |
| 同ページの `rowDelimiter` | 読み込みの既定値は `["\r\n", "\r", "\n"]` のいずれか。「**"\r\n" is only supported in copy command.**」 | 変更後の `"\r\n"` 指定は Copy activity でサポートされる (Data Flow では不可)。また `rowDelimiter` を省略すれば CRLF / LF のどちらでも読める |
| [Q&A: ADF Copy Activity Encoding UTF-8-BOM](https://learn.microsoft.com/en-us/answers/questions/131270/adf-copy-activity-encoding-utf-8-bom) (2020-10) | UTF-8 BOM 付きファイルを読むのにどの encoding を使うかという質問。回答「UTF-8 を試しては」に対し、質問者が「the suggestion did the trick」と解決を報告 | BOM 付きファイルは `UTF-8` 指定の Copy で読めたという事例 (今回の実測と同じ) |
| [Q&A: ADF UTF-8 without BOM](https://learn.microsoft.com/en-us/answers/questions/416813/adf-utf-8-without-bom) (2021-06、Microsoft 回答) | 「**ADF Copy will generate UTF-8 BOM file if the encoding property in target Dataset is explicitly specified.**」BOM なしで出力したい場合は `Default(UTF-8)` を使う | **書き込み側**の挙動。今回の実測で archive の出力 CSV に BOM が付いていたことと一致する |
| [Q&A: Preview ... failed with "UTF-8 without BOM"](https://learn.microsoft.com/en-us/answers/questions/777584/preview-at-source-dataset-of-copy-data-activity-fa) (2022-03) | 読み込み側の Dataset に `UTF-8 without BOM` を指定すると、データプレビューが「'UTF-8 without BOM' is not a supported encoding name」で失敗する (パイプライン実行は成功) | 読み込み側の Dataset は `UTF-8` を指定するのが無難 (変更後の定義は `UTF-8` なので問題なし) |
| [Q&A: Copy Activity Not Recognizing an Existing Column in a CSV File](https://learn.microsoft.com/en-my/answers/questions/5601012/copy-activity-not-recognizing-an-existing-column-i) (2025-10) | 数か月動いていた Copy が突然「列がソースファイルに見つからない」で失敗するようになった事例。Microsoft 側の回答者が「最近のバックエンド更新で、BOM などのエンコーディングマーカーを含むファイルのヘッダ解析がわずかに変わった」と言及。**BOM が原因だったとは確認されていない**。回避策は、ヘッダ無し扱い + 列番号でのマッピング | **リスク**: ヘッダ名でマッピングしている本パイプラインは、ADF 側の変更でヘッダの解釈が変わると失敗しうる。BOM の扱いは仕様として保証されたものではない |

まとめ:

- Copy activity + `encodingName: "UTF-8"` なら、BOM 付き UTF-8 を問題なく読める (実測済み。公開事例とも一致)。
- ただし「読み込み時に BOM を除去する」という公式の明記は無く、仕様として保証されたものではない。
  運用後に `MappingColumnNameNotFoundInSourceFile` が出た場合は、まず BOM の扱いの変化を疑う。
  回避策は、BOM なしでアップロードしてもらうこと (BOM なしでも変更後の設定で読めることは実測済み)。
- Mapping Data Flow に移行する場合は BOM 付きが非対応なので、この前提は成り立たない。

## 模擬の前提

Copy activity の挙動のうち、以下を前提に模擬している。BOM の除去とマッピング元の列が無い場合の失敗は、上記の実測で既定の前提どおりであることを確認済み。

| 前提 | 既定 | 切替 | 備考 |
|------|------|------|------|
| `UTF-8` で読むと先頭の BOM を除去する | 除去 | `--bom keep` | 除去されない場合はヘッダが `﻿顧客_番号` になり、**新フォーマットも COPY_FAILED** になる (本命の比較も FAIL) |
| マッピング元の列がヘッダに無いと Copy が失敗する | 失敗 | `--missing-column null` | 失敗しない場合は該当列が NULL になり、全行が `... required` で error に振り分けられる |
| `rowDelimiter` を明示すると、その文字列だけで行を区切る | — | — | 変更前の設定で CRLF のファイルを読むと、各行の最終列に `\r` が残る前提 |
| `shift_jis` は CP932 として読み、デコードできないバイトは置換文字にする (例外にしない) | — | — | |
| 空文字は NULL として扱う (`nullValue` の既定値) | — | — | |

実機で裏取りするときは、変更後の `ds_src_csv` を持つ ADF を [`azure/`](./azure/README.md) で構築し、
`azure/run_adf.py` で `inputs/*.csv` を流すとローカル模擬の結果と自動で突き合わせられる。
