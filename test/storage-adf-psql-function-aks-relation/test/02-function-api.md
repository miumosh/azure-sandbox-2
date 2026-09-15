# 経路2: Function API にリクエストを投入して結果を確認する

本人特定 API `POST /api/customers/search` に成功パターン・失敗パターンを投げ、
`result_code`（`MATCH` / `NOT_FOUND` / `BAD_REQUEST` / `ERROR`）と `policy_no` が期待どおりかを確認する。

前提と共通の環境変数は [README.md](./README.md) を参照。
**先に [01-storage-csv.md](./01-storage-csv.md#0-前提データを投入する) の前提データ投入を済ませておくこと**
（`scenario_known_person.csv` の 6 行が `customer_info_production` に入っている状態）。

---

## 1. 投入口は 2 つある（層が違うので結果も違う）

```
経路2-A  [VM] --curl -d @F-xxx.json (JSON + x-functions-key)--------------> [Functions] --> [PostgreSQL]
         └ Function PE に NW 疎通できる VM

経路2-B  [ローカル] --form--> [AKS person-id-app (FastAPI)] --JSON + key--> [Functions] --> [PostgreSQL]
                              └ 公開 LB
```

| | 経路2-A: Function 直叩き | 経路2-B: AKS 経由 |
| --- | --- | --- |
| 実行場所 | **Function の PE に NW 疎通できる VM**（Function は PE 専用＋`snet-pe-func-nsg` で許可サブネットのみ。ローカル端末や踏み台からは到達不可） | ローカル端末（公開 LB なのでどこからでも可） |
| 宛先 | `$FUNC_URL/api/customers/search` | `http://<AKS_EXTERNAL_IP>/api/customers/search` |
| 送り方 | **`curl` でリクエスト JSON をパス指定**（`-d @<file>`）+ `x-functions-key` | form（`-F`） |
| 見えるもの | **API 仕様そのもの**（HTTP ステータス・`result_code`・401 等） | 中継層込みの E2E（FastAPI の検証が先に効く） |

**層の差で必ず押さえる 2 点**（ローカル再現で確認済み）:

1. **必須項目の欠落・空文字は AKS 層（FastAPI の `Form(...)`）で 422 になり、Function に届かない。**
   `-F "birth_ymd="` のように空文字を送っても 422（`{"detail":[{"type":"missing",...}]}`）。
2. **AKS の中継 API は Function の HTTP ステータスを引き継がない。** `main.py` が Function のレスポンス JSON を
   そのまま return するため、Function が 400 を返しても AKS 経由では **HTTP 200 + `result_code=BAD_REQUEST`** に見える。

---

## 2. 実行手順

### 準備 1: リクエスト JSON とケース定義（生成済み。作り直す場合のみ）

```bash
python3 test/scripts/api/generate_api_requests.py   # 出力先の既定は test/data/api-requests
# test/data/api-requests/<case_id>.json  … 個別のリクエストボディ（curl -d @ で渡す）
# test/data/api-requests/<case_id>.txt   … JSON として不正なケース（壊れた JSON 等）をそのまま出力
# test/data/api-requests/cases.json      … 全ケースの定義 + 期待値（期待値表の元データ）
```

### 準備 2: VM にリクエスト JSON と接続情報を置く

`test/data/api-requests/` 一式を、**Function の PE に NW 疎通できる VM** に配置する（転送手段は問わない）。
VM 作成や NW 設定は本書の対象外（前提は [README.md](./README.md#前提) 参照）。接続情報はローカルで取得して VM 側で設定する。

```bash
# ローカル（リポジトリルート）で取得
terraform -chdir=terraform/envs/spoke-subscription output -raw function_app_base_url
terraform -chdir=terraform/envs/spoke-subscription output -raw function_default_key

# VM 側で設定（以降の curl はこの 3 つを前提にする）
export FUNC_URL="https://<function-app>.azurewebsites.net"
export FUNC_KEY="<function key>"
export REQ_DIR="$HOME/api-requests"      # リクエスト JSON を置いたディレクトリ
```

疎通できているかの確認（キー無しなので **401 が返れば PE まで届いている**。名前解決できない／タイムアウトする場合は NSG か DNS）:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$FUNC_URL/api/customers/search"
```

### 経路2-A: VM から Function を直叩き（curl でリクエスト JSON をパス指定）

1 ケース = 1 ファイルなので、**ファイルパスを指定して投げる**。

```bash
# 基本形（成功系・入力不備系はすべてこの形）
curl -s -i -X POST "$FUNC_URL/api/customers/search" \
  -H "Content-Type: application/json" \
  -H "x-functions-key: $FUNC_KEY" \
  -d @"$REQ_DIR/F-A02.json"
# -> HTTP/1.1 200 ... {"result_code":"MATCH","policy_no":["0000000001","0000000002","0000000003"]}
```

ケースの種類ごとに変える点は次のとおり（`ID` は §3 の表と `cases.json` に対応）。

| 対象 | 変える点 | 例 |
| --- | --- | --- |
| F-A01〜A12 / F-B01〜B06 / F-C01〜C10 | 基本形のままファイル名だけ変える | `-d @"$REQ_DIR/F-B03.json"` |
| F-C11〜F-C15（JSON として不正なボディ） | ファイルが `.txt` | `-d @"$REQ_DIR/F-C11.txt"` |
| F-C15（form 形式で直叩き） | `Content-Type` を form にする | `-H "Content-Type: application/x-www-form-urlencoded" -d @"$REQ_DIR/F-C15.txt"` |
| F-A13（キーをクエリで渡す） | ヘッダを付けず `?code=` を付ける | `curl -s -i -X POST "$FUNC_URL/api/customers/search?code=$FUNC_KEY" -H "Content-Type: application/json" -d @"$REQ_DIR/F-A13.json"` |
| F-D01（キー無し） | `x-functions-key` を付けない | `-d @"$REQ_DIR/F-D01.json"` |
| F-D02（不正なキー） | 値をでたらめにする | `-H "x-functions-key: invalid-key-0000000000000000"` |
| F-D03（GET） | `-X GET` でボディ無し | `curl -s -i -X GET "$FUNC_URL/api/customers/search" -H "x-functions-key: $FUNC_KEY"` |
| F-D04（存在しないパス） | パスを変える | `curl -s -i -X POST "$FUNC_URL/api/customers/searchx" -H "x-functions-key: $FUNC_KEY" -d @"$REQ_DIR/F-D04.json"` |

`-i` を付けて **HTTP ステータス**（200 / 400 / 401 / 404）と**ボディ**の両方を見る。ステータスだけ欲しいときは
`-o /dev/null -w '%{http_code}\n'` にする。

まとめて流す場合（1 ケースずつ結果を目視で突き合わせる）:

```bash
for f in "$REQ_DIR"/F-A*.json "$REQ_DIR"/F-B*.json "$REQ_DIR"/F-C*.json; do
  printf '=== %s\n' "$(basename "$f")"
  curl -s -w '  <- HTTP %{http_code}\n' -X POST "$FUNC_URL/api/customers/search" \
    -H "Content-Type: application/json" -H "x-functions-key: $FUNC_KEY" -d @"$f"
done
```

> 期待値は §3 の表、または `cases.json` の `expect`（`status` / `result_code` / `policy_no` / `message_contains`）を見る。
> `F-A13` / `F-C15` / `F-D01`〜`F-D04` は上表のとおり投げ方が違うため、このループからは外して個別に叩くこと。

### 経路2-B: AKS 公開 IP へ form で投入

公開 LB なのでローカル端末からでも VM からでも実行できる。**JSON ではなく form で送る**（AKS 側は `Form(...)` で受ける）。

```bash
IP=$(kubectl get svc person-id-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s -X POST "http://$IP/api/customers/search" \
  -F "name_kana=タナカ　タロウ" -F "birth_ymd=19900101" -F "cellular_phone_no=090-1111-2222"
# -> {"result_code":"MATCH","policy_no":["0000000001","0000000002","0000000003"]}
```

送る値は各ケースの JSON（`test/data/api-requests/F-xxx.json`）の 3 項目をそのまま `-F` に写す。
ブラウザで `http://<AKS_EXTERNAL_IP>/` を開けば同じことを Web UI から実行できる（結果は自動更新されないのでリロードする）。

---

## 3. パターン一覧

`ID` は `test/data/api-requests/cases.json` および各リクエストファイル名と一致する。
「直叩き期待」（経路2-A: VM から curl）「AKS 経由期待」（経路2-B）はローカル再現（実装コードをそのまま
動かした環境）で**全ケース PASS を確認済み**。実機での確証は §2 の curl で取る。

### A. 成功（`200 MATCH`）

正規化（NFKC・空白の畳み込み・ダッシュ類の統一）で表記揺れを吸収して一致するケース。

| ID | 入力の特徴 | 例 | 直叩き期待 | AKS 経由期待 | 備考 |
| --- | --- | --- | --- | --- | --- |
| F-A01 | 完全一致 1 件 | `スズキ　ハナコ` / `19851215` / `080-3333-4444` | 200 `MATCH` `["0000000004"]` | 同左 | |
| F-A02 | **同一人物が複数 policy_no** | `タナカ　タロウ` / `19900101` / `090-1111-2222` | 200 `MATCH` `["0000000001","0000000002","0000000003"]` | 同左 | `ORDER BY policy_no` の昇順 |
| F-A03 | 姓名の区切りが半角スペース | `タナカ タロウ` | 200 `MATCH` 3 件 | 同左 | `\s+` → 全角スペース 1 個へ正規化 |
| F-A04 | 前後・連続空白 | `␣␣タナカ␣␣␣タロウ␣␣` | 200 `MATCH` 3 件 | 同左 | `strip()` + 空白畳み込み |
| F-A05 | 氏名が半角カナ | `ﾀﾅｶ ﾀﾛｳ` | 200 `MATCH` 3 件 | 同左 | NFKC で全角カナ化 |
| F-A06 | 生年月日が全角数字 | `１９９００１０１` | 200 `MATCH` 3 件 | 同左 | NFKC |
| F-A07 | 電話が全角数字 + 長音記号 | `０９０ー１１１１ー２２２２` | 200 `MATCH` 3 件 | 同左 | ダッシュ類（`ー` 含む）を ASCII ハイフンへ |
| F-A08 | 電話に空白混じり | `090 - 1111 - 2222` | 200 `MATCH` 3 件 | 同左 | 空白除去 |
| F-A09 | 電話が全角ハイフン | `０９０－１１１１－２２２２` | 200 `MATCH` 3 件 | 同左 | NFKC |
| F-A10 | 境界値（氏名 50 文字 / 閏日） | 50 文字カナ / `20240229` / `090-0000-0001` | 200 `MATCH` `["AB12345678"]` | 同左 | 上限ちょうどは通る |
| F-A11 | 値が**数値型** | `"birth_ymd": 19900101`（JSON の数値） | 200 `MATCH` 3 件 | 同左 | `str()` で文字列化されるため通る |
| F-A12 | 未知のキーを含む | `{"…", "policy_no":"9999999999"}` | 200 `MATCH` `["0000000004"]` | 同左 | 余分なキーは無視される |
| F-A13 | キーをクエリで渡す | `?code=<FUNCTION_KEY>` | 200 `MATCH` `["0000000004"]` | — | AKS 経由はキー付与がアプリ側の責務のため対象外 |

### B. 照合成功・該当なし（`200 NOT_FOUND`）

**「見つからない」は 400 ではなく 200**。ここに入るものを 400 と混同しないこと。

| ID | 入力の特徴 | 例 | 直叩き期待 | AKS 経由期待 | 備考 |
| --- | --- | --- | --- | --- | --- |
| F-B01 | 存在しない人 | `ナイ　ヒト` / `20201231` / `000-0000-0000` | 200 `NOT_FOUND` `[]` | 同左 | |
| F-B02 | 3 項目のうち**電話だけ違う** | `タナカ　タロウ` / `19900101` / `090-9999-9999` | 200 `NOT_FOUND` | 同左 | 3 項目 AND の完全一致 |
| F-B03 | 姓名の区切りが無い | `タナカタロウ` | 200 `NOT_FOUND` | 同左 | 正規化は区切りを**補わない**。DB は `姓＜U+3000＞名` |
| F-B04 | 氏名がカタカナでない | `tanaka taro` | 200 `NOT_FOUND` | 同左 | **Function は文字種を検証しない**（長さのみ）。文字種検証は SQL 側だけ |
| F-B05 | 実在しない日付 | `20260230` | 200 `NOT_FOUND` | 同左 | Function は 8 桁数字しか見ない。実在日検証は SQL 側だけ |
| F-B06 | 電話が 2-4-4 | `03-1111-2222` | 200 `NOT_FOUND` | 同左 | 実装の正規表現は `^[0-9]{2,4}-[0-9]{2,4}-[0-9]{4}$` で**仕様書（3-4-4）より緩い** |

> F-B04 / F-B05 / F-B06 は「**Function と SQL でバリデーション強度が違う**」ことの確認ケース。
> SQL 側なら error になる入力が、API では BAD_REQUEST ではなく NOT_FOUND になる。

### C. 入力不備（直叩き `400 BAD_REQUEST` / AKS 経由は 422 か 200+BAD_REQUEST）

| ID | 入力の特徴 | 直叩き期待 | AKS 経由期待 | 備考 |
| --- | --- | --- | --- | --- |
| F-C01 | `name_kana` 欠落 | 400 `BAD_REQUEST`「入力パラメータが不足しています: name_kana」 | **422**（FastAPI） | Function に届かない |
| F-C02 | 3 項目すべて欠落（`{}`） | 400「…: name_kana, birth_ymd, cellular_phone_no」 | **422** | 不足項目が列挙される |
| F-C03 | `birth_ymd` が空文字 | 400「…: birth_ymd」 | **422** | 空文字は falsy = 欠落扱い。form でも空文字は missing 判定 |
| F-C04 | `cellular_phone_no` が `null` | 400「…: cellular_phone_no」 | **422** | form では null を送れないため空文字 → 422 |
| F-C05 | `name_kana` 51 文字 | 400「…(name_kana は全角カナ 50 文字以内)」 | **200** + `BAD_REQUEST` | 上限は 50 |
| F-C06 | `birth_ymd` 7 桁 | 400「…(birth_ymd は YYYYMMDD)」 | 200 + `BAD_REQUEST` | |
| F-C07 | `birth_ymd` が 8 文字だが非数字（`1990/1/1`） | 400「…(birth_ymd は YYYYMMDD)」 | 200 + `BAD_REQUEST` | |
| F-C08 | 電話ハイフン無し（`09011112222`） | 400「…(cellular_phone_no は XXX-XXXX-XXXX)」 | 200 + `BAD_REQUEST` | |
| F-C09 | 電話 3-4-3（`090-1111-222`） | 400「…(cellular_phone_no は …)」 | 200 + `BAD_REQUEST` | 末尾は 4 桁固定 |
| F-C10 | 電話の先頭 5 桁（`09012-1111-2222`） | 400「…(cellular_phone_no は …)」 | 200 + `BAD_REQUEST` | 先頭は 2〜4 桁 |
| F-C11 | 壊れた JSON（`{"name_kana":`） | 400「リクエストボディが不正な JSON です。」 | — | form では表現できない |
| F-C12 | ボディが空 | 400「リクエストボディが不正な JSON です。」 | — | 〃 |
| F-C13 | ボディが JSON 配列（`[]`） | 400「リクエストボディは JSON オブジェクトである必要があります。」 | — | 〃 |
| F-C14 | ボディが JSON 文字列（`"abc"`） | 400「…JSON オブジェクトである必要があります。」 | — | 〃 |
| F-C15 | form 形式で**直叩き** | 400「リクエストボディが不正な JSON です。」 | — | Function は Content-Type を見ずに JSON パースする |

> `message` は**項目名と汎用文言のみ**で、入力値（PII）を含まない。ログにも値は出さない設計
> （[../docs/api-customer-search.md](../docs/api-customer-search.md) §6）。テスト時もこの点を目視確認するとよい。

### D. プラットフォーム層（`result_code` を含まない）

Functions ホストが返すため、ボディは JSON 契約の形ではない。

| ID | 入力の特徴 | 直叩き期待 | AKS 経由 | 備考 |
| --- | --- | --- | --- | --- |
| F-D01 | `x-functions-key` 無し | **401** | — | キー付与は AKS アプリの責務 |
| F-D02 | 不正なキー | **401** | — | |
| F-D03 | `GET` でアクセス | **404**（ルートは POST のみ）※Functions ホストの挙動は未実測 | — | |
| F-D04 | 存在しないパス（`/api/customers/searchx`） | **404** ※未実測 | — | |

### E. サーバエラー（`5xx ERROR`）— 任意・環境操作を伴う

DB 側を意図的に止めて初めて再現できるため、**必要なときだけ**実施する（元に戻す手順まで含めて計画すること）。

| ID | 起こし方 | 直叩き期待 | AKS 経由期待 | 備考 |
| --- | --- | --- | --- | --- |
| F-E01 | PostgreSQL を停止する（`az postgres flexible-server stop`）／Function の MI から `SELECT` 権限を剥奪する | **500** `{"result_code":"ERROR","message":"<DB 例外詳細>"}` | 200 + `result_code=ERROR`。**AKS 側で最大 3 回リトライ**（0.5s → 1.0s のバックオフ）してから ERROR を返す | `message` には DB 例外詳細が入る（PII ではないが DB 内部情報） |

### K. AKS 中継層に固有のパターン

`cases.json` の対象外（パスやレスポンス形式が違う）。ローカル端末から手で確認する。

| ID | 入力 | 期待 | 確認コマンド |
| --- | --- | --- | --- |
| K-01 | ヘルスチェック | 200 `{"status":"ok"}` | `curl -s http://$IP/health` |
| K-02 | トップページ | 200 HTML（検索フォーム） | `curl -s -o /dev/null -w '%{http_code}' http://$IP/` |
| K-03 | フォーム送信（HTML 応答） | 200 HTML に `result_code = MATCH` と `policy_no` の一覧 | `curl -s -X POST http://$IP/ -F "name_kana=タナカ　タロウ" -F "birth_ymd=19900101" -F "cellular_phone_no=090-1111-2222"` |
| K-04 | JSON で送る（form 期待の API に） | **422**（`Form(...)` に値が無い） | `curl -s -X POST http://$IP/api/customers/search -H 'Content-Type: application/json' -d '{"name_kana":"タナカ　タロウ","birth_ymd":"19900101","cellular_phone_no":"090-1111-2222"}'` |
| K-05 | 存在しないパス | 404（FastAPI） | `curl -s -o /dev/null -w '%{http_code}' http://$IP/nope` |

> K-04 は「AKS の API は form でしか受け付けない」ことの確認。JSON を投げたいときは経路2-A（Function 直叩き）を使う。

---

## 4. 経路1 との突き合わせ（層による違いのまとめ）

同じ値でも、**CSV 取り込み（SQL）と API（Function）でどちらが厳しいか**が違う。設計どおりであることを確認する観点。

| 入力 | 経路1（`validation.sql`） | 経路2（Function） |
| --- | --- | --- |
| 氏名がカタカナでない（`tanaka taro`） | error `name_kana must be zenkaku katakana …` | **検証しない** → `NOT_FOUND` |
| 姓名の区切りが半角スペース | error（全角スペース必須） | **正規化して全角へ** → `MATCH` |
| 実在しない日付（`20260230`） | error `birth_ymd is not a valid calendar date` | **検証しない**（8 桁数字なら通る）→ `NOT_FOUND` |
| 電話 2-4-4（`03-1111-2222`） | error（3-4-4 固定） | **通る**（`{2,4}-{2,4}-{4}`）→ `NOT_FOUND` |
| 電話が全角 | error | **正規化して半角へ** → `MATCH` |
| 氏名 51 文字 | error `name_kana too long (max 50)` | `BAD_REQUEST` |

> つまり **DB に入る値は SQL 側で担保され、API 側は「照合できる形か」だけを見る**。
> API を厳しくしたい場合（例: カタカナ以外を BAD_REQUEST にする）は `api.py` の `validate_format` に規則を足す。

---

## 5. 後片付け

経路2 はデータを変更しないため後片付けは不要。経路1 で異常系 CSV を流した場合は
[01-storage-csv.md §4](./01-storage-csv.md#4-後片付け) で production を戻す。
