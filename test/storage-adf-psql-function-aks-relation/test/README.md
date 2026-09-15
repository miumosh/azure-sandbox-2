# 手動テスト手順（2 経路）

本システムを**手で動かして確認する**ための手順書とテストデータ一式。入口が 2 つあるので経路ごとに分けている。

| 経路 | 入口 | 何を確かめるか | 手順書 |
| --- | --- | --- | --- |
| **経路1** | Storage に CSV を投入（**手動アップロード**） | CSV → ADF `pl_csv_ingest` → PostgreSQL の**取り込みとバリデーション**（成功行が `customer_info_production` に、違反行が理由付きで `customer_info_error` に入る） | [01-storage-csv.md](./01-storage-csv.md) |
| **経路2** | Function API にリクエスト（**VM から curl**） | `POST /api/customers/search` の**照合と入力検証**（MATCH / NOT_FOUND / BAD_REQUEST / ERROR）と、AKS 中継層との挙動差 | [02-function-api.md](./02-function-api.md) |

```
── 経路1 ────────────────────────────────────────────────────────────────────────
[手動アップロード] --CSV--> [Storage input/] --BlobCreated--> [ADF pl_csv_ingest] --> [PostgreSQL]
                                                                                          ↑
── 経路2 ────────────────────────────────────────────────────────────────────────         │
[VM] --curl -d @F-xxx.json (JSON + x-functions-key)-------------------> [Functions] ──────┤
[ローカル] --form--> [AKS person-id-app]（公開 LB）--JSON + key-------> [Functions] ──────┘
```

経路1 で `customer_info_production` を作り、経路2 でそれを引く。**経路2 は経路1 の結果に依存する**ため、
先に経路1 の「[前提データの投入](./01-storage-csv.md#0-前提データを投入する)」を実施しておくこと。

なお、テスト仕様書（成果物としての一覧表）を**別の AI に書かせる**ための指示書を
[03-test-spec-authoring-prompt.md](./03-test-spec-authoring-prompt.md) に用意している。

---

## 前提

- Hub / Spoke の Terraform が apply 済みで、Function・AKS・ADF・PostgreSQL が稼働している（[../README.md](../README.md) 手順 1〜6）。
- **CSV の Storage へのアップロードは手動で行う**（Storage Explorer / ポータル / `az` など手段は問わない）。
  本書はアップロードの操作手順そのものは扱わない。投入先と規定名だけ守ること（[01-storage-csv.md](./01-storage-csv.md) 参照）。
- **Function API のテストは、Function の Private Endpoint に NW 疎通できる VM から `curl` で実施する**。
  VM の作成手順は本書の対象外。次を満たす VM を用意しておくこと。
  - `snet-pe-func-nsg` の許可対象サブネットに配置されている（既定では `snet-aks` のみ許可。
    別サブネットの VM を使う場合は NSG に許可を追加する。[../docs/network.md](../docs/network.md)）。
  - `privatelink.azurewebsites.net` の Private DNS ゾーンで Function 名を解決できる。
  - `curl` が入っている。リクエスト JSON（`test/data/api-requests/`）をこの VM に配置しておく。
- `az` / `terraform` / `kubectl` / `python3`（3.10+）が使える。`kubectl` は `az aks get-credentials` 済み
  （AKS 経由の確認に使う）。

### 共通の環境変数

各手順書のコマンドはこの変数群を前提にする。**リポジトリルート**（本ディレクトリの 1 つ上）で実行する。

```bash
HUB_TF=terraform/envs/hub-subscription
SPOKE_TF=terraform/envs/spoke-subscription

HUB_RG=$(terraform -chdir=$HUB_TF output -raw resource_group_name)
HUB_SUB=$(terraform -chdir=$HUB_TF output -raw subscription_id)
ADF=$(terraform -chdir=$HUB_TF output -raw data_factory_name)
ACCT=$(terraform -chdir=$HUB_TF output -raw storage_account_name)
CONT=$(terraform -chdir=$HUB_TF output -raw upload_container_name)

SPOKE_RG=$(terraform -chdir=$SPOKE_TF output -raw resource_group_name)
SPOKE_SUB=$(terraform -chdir=$SPOKE_TF output -raw subscription_id)
PSQL_FQDN=$(terraform -chdir=$SPOKE_TF output -raw psql_fqdn)

# 経路2 で VM に渡す接続情報（VM 側の環境変数として設定する）
FUNC_URL=$(terraform -chdir=$SPOKE_TF output -raw function_app_base_url)
FUNC_KEY=$(terraform -chdir=$SPOKE_TF output -raw function_default_key)

# ADF の run 検索で使う期間（十分広く取る）
AFTER=2026-01-01T00:00:00Z
BEFORE=2099-01-01T00:00:00Z
```

---

## ディレクトリ構成

```
test/
├── README.md                        本書（前提・データの読み方・スクリプト一覧）
├── 01-storage-csv.md                経路1 の手順とパターン一覧
├── 02-function-api.md               経路2 の手順とパターン一覧
├── 03-test-spec-authoring-prompt.md テスト仕様書を別 AI に作らせるための指示書
├── data/
│   ├── csv/                         経路1 のテストデータ（Shift_JIS / LF / ヘッダ有り）
│   └── api-requests/                経路2 のリクエスト JSON と期待値付き cases.json
└── scripts/
    ├── csv/                         テストデータ（CSV）の生成・期待値シミュレータ
    └── api/                         リクエスト JSON の生成
```

`data/` 配下は**生成物だが commit 対象**（テストの入力そのものであり、期待値が手順書の表と 1 対 1 で対応するため）。
リポジトリルートの `csv/` と `api-requests/` は従来の作業ディレクトリで `.gitignore` 済み。**正本は `test/data/` 側**。

---

## テストデータ（CSV）の読み方 — 接頭辞ごとの違い

`data/csv/` には接頭辞の違う 4 系統のファイルがある。**目的も生成元も違う**ので混同しないこと。

| 接頭辞 | 生成元 | 1 ファイルの粒度 | 内容の決定性 | 位置づけ |
| --- | --- | --- | --- | --- |
| `valid` | `scripts/csv/generate_sample_csv.py` | 正常系のみをまとめて大量 | 乱数（seed 固定なので再生成すれば同じ） | 本番相当データの投入・**テスト後の復旧**用 |
| `invalid_<種別>` | `scripts/csv/generate_invalid_csv.py` | **違反種別 1 つ**（正常 n 行 + 違反 m 行） | 乱数（seed 固定）。行数を引数で変えられる | 件数ベースの確認（`rowsRead` 突合）。量を増やせる**量産型** |
| `scenario_<観点>` | `scripts/csv/generate_scenario_csv.py` | **観点 1 つ**（少行数・固定値） | 完全に決定的（乱数なし） | **網羅テストの正本**。手順書の期待値表と 1 対 1 で対応する |
| `q<n>_<名前>` / `multi_policy` | 手製（再生成スクリプト無し） | 当時の質問 1 件を確認するためのアドホック | 固定（手で書いたまま） | **履歴**。原則 `scenario_` を使う |

### `valid.csv`

`generate_sample_csv.py` が出す正常系のみの CSV。既定は 10 万件（現物は 1,000 行）。
全行が `customer_info_production` に入る。異常系を流した後に**本番相当データへ戻す**ときに使う。

### `invalid_xxx.csv` — 違反種別ごとの量産型

`generate_invalid_csv.py --valid 5 --per-category 2` で生成した 8 ファイル。1 ファイルにつき違反はひとつの種別だけで、
**正常 5 行 + 違反 2 行**（重複のみ 2 組 4 行）が混ざる。`--valid` / `--per-category` を変えれば行数を増減できるため、
「件数が期待どおり振り分けられるか」を量で確かめる用途に向く。氏名や生年月日などの正常値は乱数で埋まる。

| ファイル | 違反させる項目 | 期待 `error_message` | 期待（production / error） |
| --- | --- | --- | --- |
| `invalid_id_empty.csv` | policy_no 空欄 | `policy_no required` | 5 / 2 |
| `invalid_name_hiragana.csv` | 氏名がひらがな | `name_kana must be zenkaku katakana …` | 5 / 2 |
| `invalid_birthdate_7digit.csv` | 生年月日 7 桁 | `birth_ymd must be 8 digits` | 5 / 2 |
| `invalid_phone_nodash.csv` | 電話ハイフン無し | `cellular_phone_no must be XXX-XXXX-XXXX` | 5 / 2 |
| `invalid_id_overlength.csv` | policy_no 11 文字 | `policy_no too long (max 10)` | 5 / 2 |
| `invalid_name_overlength.csv` | 氏名 60 文字 | `name_kana too long (max 50)` | 5 / 2 |
| `invalid_id_duplicate.csv` | 同一 policy_no 2 組 | `policy_no duplicated`（重複行は全行 NG） | 5 / 4 |
| `invalid_mixed.csv` | 上記を全部混在 | 種別ごとに 2 件ずつ | 5 / 16 |

> `invalid_overlength_loadfail.csv` だけは**旧構成時代の手製ファイル**で、列構成が現行と違う（5 列・ヘッダ無し）。
> 現行仕様では使えない。255 文字超のロード失敗を見たい場合は `scenario_loadfail_over255.csv` を使う。

### `scenario_xxx.csv` — 1 ファイル = 1 観点の固定値シナリオ

`generate_scenario_csv.py` が出す 12 ファイル。乱数を使わないため**毎回まったく同じ内容**になり、
期待値（production 件数・error の内訳）を手順書に固定できる。網羅テストはこの系統で行う。
一覧と期待値は [01-storage-csv.md §2-A](./01-storage-csv.md#2-パターン一覧) にある。

観点の区分:

- **正常系**: `scenario_known_person.csv`（経路2 の前提データ）/ `scenario_boundary_ok.csv`（境界値だが全行合格）
- **行レベルの違反**: `scenario_blank_only.csv`（必須）/ `scenario_length.csv`（桁数）/ `scenario_charset.csv`（文字種・形式）/
  `scenario_calendar.csv`（実在日）/ `scenario_duplicate.csv`（policy_no 重複）
- **ファイル・ロードレベル**: `scenario_header_only.csv`（データ 0 行）/ `scenario_loadfail_over255.csv`（255 文字超 = 唯一の pipeline 失敗系）/
  `scenario_utf8_encoding.csv`（規定外エンコーディング）/ `scenario_crlf.csv`（規定外改行）/ `scenario_bad_header.csv`（ヘッダ名不一致）

### `q(n)_xxx.csv` / `multi_policy.csv` — 過去の質問への回答を確認したアドホックファイル

`scenario_` 系を整備する前に、仕様相談で出た質問（`n` は当時の質問番号）へその場で答えるために手で作った CSV。
**生成スクリプトは無く**、内容は書いたまま固定。現在はいずれも `scenario_` 系にほぼ取り込まれているので、
**新しいテストでは原則使わない**（確認の履歴として残してある）。

| ファイル | 当時の確認内容 | 内容 | 現在の代替 |
| --- | --- | --- | --- |
| `q2_all_invalid.csv` | 必須チェック強化後、**全行が違反**になったとき production はどうなるか | 2 行とも policy_no 空 → error 2 / production **0** | 完全な代替は無い（`scenario_header_only.csv` は「入力 0 行」、こちらは「入力はあるが valid 0 行」）。**この観点は本ファイルのみ** |
| `q3_calendar.csv` | 実在日チェックの追加が効いているか | 正常 3 行 + `20260230` / `20260431` → error 2 / production 3 | `scenario_calendar.csv`（10 行・非実在日 7 種） |
| `q3_edge.csv` | 実在日チェックの境界（閏年・月末） | `20240229` / `20000229` / 月末は OK、`19000229` / `20260230` 等は NG の 9 行 | `scenario_boundary_ok.csv` + `scenario_calendar.csv` |
| `multi_policy.csv` | 同一人物が複数 policy_no を持つとき重複扱いされないか | 同一人物 3 行 + 一意 2 行 | `scenario_known_person.csv`（同じ 5 行 + 境界値 1 行） |

> `q2_all_invalid.csv` の観点（valid 0 行 → production が空になる）は現行の網羅表に入っていない。
> 経路1 の L-07（ヘッダのみ）と合わせて確認しておくとよい。

### `data/api-requests/` — 経路2 のリクエストデータ

`scripts/api/generate_api_requests.py` の生成物。`<case_id>.json` が 1 ケース分のリクエストボディで、
そのまま `curl -d @<file>` に渡せる。壊れた JSON など JSON として不正なケースは `.txt` で出力される。
`cases.json` に全ケースの定義と**期待値**（HTTP ステータス / `result_code` / `policy_no` / メッセージ断片）が入っている。

検索キーは `scenario_known_person.csv` の値と一致させてある。**片方を変えたら両方直すこと**
（`generate_scenario_csv.py` の `MULTI_*` / `SINGLE_*` と `generate_api_requests.py` の同名定数）。

---

## テストに使うスクリプト

いずれも Python 標準ライブラリのみで動作する（追加パッケージ不要 / Python 3.10+）。**リポジトリルートで実行する**。

| スクリプト | 役割 |
| --- | --- |
| `test/scripts/csv/generate_sample_csv.py` | 正常系 CSV（既定 10 万件）を生成 |
| `test/scripts/csv/generate_invalid_csv.py` | 違反種別ごとの CSV を量産（正常 n 行 + 違反 m 行） |
| `test/scripts/csv/generate_scenario_csv.py` | **1 ファイル = 1 観点**の固定値シナリオ CSV を生成（経路1 の網羅表に対応） |
| `test/scripts/csv/simulate_validation.py` | `validation.sql` を再現して**投入前に期待値を確定**する |
| `test/scripts/api/generate_api_requests.py` | 経路2 のリクエスト JSON と期待値付き `cases.json` を生成 |

```bash
# CSV（既定の出力先は test/data/csv）
python3 test/scripts/csv/generate_scenario_csv.py
python3 test/scripts/csv/generate_invalid_csv.py --valid 5 --per-category 2
python3 test/scripts/csv/generate_sample_csv.py --rows 100000

# 期待値の事前確定（引数なしで test/data/csv/*.csv を一括）
python3 test/scripts/csv/simulate_validation.py test/data/csv/scenario_charset.csv

# API リクエスト JSON（既定の出力先は test/data/api-requests）
python3 test/scripts/api/generate_api_requests.py
```

> 生成しなおさなくても `test/data/` に生成済みのものが入っている。**再生成しても内容は同一**
> （`scenario_*` は乱数なし、`invalid_*` / `valid` は seed 固定）。
> `apps/` 配下にも同じ生成スクリプトがある（アップロード用シェルや Pod 経由ランナー込み）が、
> **テストの正本は `test/` 配下**とする。

---

## 確認手段とその制約

Storage（archive）と PostgreSQL は**完全閉域**で、ローカル端末からは中身を読めない。
そのため確認したいものに応じて手段を使い分ける。

| 確認したいもの | 手段 | 備考 |
| --- | --- | --- |
| パイプラインの成否・どの Activity で落ちたか | `az datafactory pipeline-run` / `activity-run` | ローカルから可 |
| `production` / `error` の**件数** | Copy アクティビティの `rowsRead`（`InputCSV`=入力全行 / `ArchiveSuccess`=production / `ArchiveError`=error） | ローカルから可。**閉域 DB に触れずに件数が取れる** |
| `error_message` の**理由** | ① `simulate_validation.py` による事前予測（`validation.sql` の CASE を同一順で再現）<br>② 踏み台 VM の `psql`（ライブ確証が要るとき） | archive CSV はローカルから読めない |
| Function の応答 | **NW 疎通可能な VM から `curl`**（直叩き）/ AKS 公開 IP へ form（中継層込み） | Function は PE 専用のため、許可サブネット外からは到達できない |

---

## テスト全体の注意

- **パイプラインは 1 ファイルずつ直列で流す。** `pl_csv_ingest` は `concurrency = 1` でキューイングされるが、
  `customer_info_production` の同期（UPSERT + DELETE）が入れ替わるため、**前の run の Succeeded を確認してから**次を投入する。
- **`customer_info_production` は毎回「今回投入した CSV の valid 行」に入れ替わる。** 異常系 CSV を流すと production は縮む。
  テスト後に本番相当データへ戻すには `valid.csv`（または `scenario_known_person.csv`）を再投入する。
- **バリデーションエラーでパイプラインは Failed にならない。** 常に Succeeded で、違反行は `customer_info_error` に入る。
  Failed になるのは 255 文字超などロード段階のエラーのみ（経路1 の L-06）。
- 手動アップロードのため投入履歴は自動記録されない。**いつ・どのファイルを投入したか**は実施者が控えておくこと
  （後から ADF の run と突き合わせるのに要る）。

## 関連

- 過去の実測結果とナレッジ: [../docs/test.md](../docs/test.md)
- パイプラインの構成・確認手順: [../docs/pipeline.md](../docs/pipeline.md)
- API 仕様: [../docs/api-customer-search.md](../docs/api-customer-search.md)
- ネットワーク（どこから何に到達できるか）: [../docs/network.md](../docs/network.md)
