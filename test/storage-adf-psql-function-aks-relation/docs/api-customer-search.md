# API 仕様書: 本人特定 API (customer-search)

`name_kana`(氏名) + `birth_ymd`(生年月日) + `cellular_phone_no`(電話番号) の 3 項目を完全一致で検索し、
一致する `policy_no` をすべて返す Azure Functions の HTTP API。

> 実装: `terraform/envs/spoke-subscription/files/function_app/customer_search/src/api.py`（Python v2 モデルの Blueprint。Blueprint + ハンドラ + 正規化/検証/入力境界/DB照合/HTTP応答 を 1 ファイルに集約）。DB 接続は同階層の `database.py`。
> Function の構成・v2 モデルのナレッジは [`python.md`](./python.md) を参照。

---

## 1. エンドポイント

| 項目 | 値 |
|------|----|
| Base URL | `https://<function-app-name>.azurewebsites.net` (例: `https://ci00-func.azurewebsites.net`) |
| Method / Path | `POST /api/customers/search` |
| Content-Type | `application/json` |
| プロトコル | HTTPS のみ |

Base URL は Terraform 出力 `function_app_base_url` (spoke) から取得する。

---

## 2. 認証

### AKS → Function (Function キー方式)

- 各リクエストに関数キーを付与する。付与方法 (いずれか):
  - ヘッダ **`x-functions-key: <FUNCTION_KEY>`** (推奨)
  - クエリ `?code=<FUNCTION_KEY>`
- キー無し / 不正キーは Functions ホストが **401** を返す。
- キーの取得元: Terraform 出力 `function_default_key` (spoke, `sensitive`)。

### Function → PostgreSQL (マネージドID)

- Function の System-assigned マネージドID に Azure Database for PostgreSQL への
  アクセス権限 (`ci00-func` ロールの `SELECT`) を付与済み。
- パスワードではなく MI が取得した AAD アクセストークンで接続する。

---

## 3. ネットワーク (到達性)

- Function は **Private Endpoint 経由のみ** (公開アクセス無効)。
- AKS サブネットから Function PE サブネットの **443** のみ許可。
- 同一 VNet で **privatelink DNS 解決ができること**が前提 (インターネット経由は不可)。

---

## 4. リクエスト

ボディ (JSON, 3 項目すべて必須):

```json
{
  "name_kana": "タナカ　タロウ",
  "birth_ymd": "19900101",
  "cellular_phone_no": "090-1111-2222"
}
```

| フィールド | 型 | 必須 | 形式 (正規化後) |
|-----------|----|----|------------|
| `name_kana` | string | ✔ | 全角カタカナ、姓名間に区切り (全角スペース) が必要 (最大 50 文字) |
| `birth_ymd` | string | ✔ | `YYYYMMDD` (8 桁) |
| `cellular_phone_no` | string | ✔ | `XXX-XXXX-XXXX` |

### 検索ロジック

```sql
SELECT policy_no FROM customer_info_production
WHERE name_kana = @name_kana AND birth_ymd = @birth_ymd AND cellular_phone_no = @cellular_phone_no
ORDER BY policy_no
```

- 3 項目はすべて **完全一致**。同一人物が複数 ID を持つ可能性があるため、
  結果は複数行返り得る前提で **`policy_no` を配列**に格納して返す。
- **SQL インジェクション対策（必須）**: クエリは**パラメータ化クエリ（プレースホルダ）**で実行する。
  `@name_kana` / `@birth_ymd` / `@cellular_phone_no`（psycopg の `%s`）はドライバがバインドし、
  入力値を文字列連結・f-string・`.format` でクエリへ埋め込まない
  （実装: `cur.execute(sql, [name_kana, birth_ymd, cellular_phone_no])`）。

### 表記揺れの正規化 (API 側で実施)

リクエスト値は照合前に正規化される。クライアントは厳密に整形しなくてよい:

- **氏名**: NFKC 正規化 (半角カナ→全角カナ 等) のうえ、姓名間スペースを **全角スペース (U+3000) 1 個**へ畳む
  (`customer_info_production` が ADF により `姓＜全角スペース＞名` で格納されるため、完全一致照合に揃える)。
  例: `タナカ タロウ` / `ﾀﾅｶ　ﾀﾛｳ` → `タナカ　タロウ`。区切りスペースなしの入力は非マッチになる。
- **電話番号**: NFKC 正規化で **全角数字→半角・全角ハイフン→半角** に寄せ、各種ダッシュ類を
  ASCII ハイフンへ統一。例: `０９０－１１１１－２２２２` → `090-1111-2222`。
- **生年月日**: 全角数字→半角に寄せる。

cURL 例:

```bash
curl -s -X POST "https://ci00-func.azurewebsites.net/api/customers/search" \
  -H "x-functions-key: <FUNCTION_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"name_kana":"タナカ　タロウ","birth_ymd":"19900101","cellular_phone_no":"090-1111-2222"}'
```

---

## 5. レスポンス

すべてのレスポンスに **`result_code`** を含む。

| ステータス | result_code | 契機 | ボディ例 |
|-----------|-------------|------|----------|
| 200 | `MATCH` | 照合成功・該当あり | `{"result_code":"MATCH","policy_no":["AB1111","CD2222"]}` |
| 200 | `NOT_FOUND` | 照合成功・該当なし | `{"result_code":"NOT_FOUND","policy_no":[]}` |
| 400 | `BAD_REQUEST` | 入力不備 (欠落 / 形式不正) | `{"result_code":"BAD_REQUEST","message":"入力パラメータの形式が不正です。"}` |
| 5xx | `ERROR` | DB 接続エラー / タイムアウト | `{"result_code":"ERROR","message":"<detail>"}` |
| 401 | — | Function キー無効 (Functions ホストが返す) | (プラットフォーム形式) |

- **照合成功は該当の有無にかかわらず 200**（`MATCH` / `NOT_FOUND`）。
- **400** は AKS 側の入力不備。リトライ不要。
- **5xx** は一時障害想定で **AKS 側でリトライ** する
  (本リポジトリの `app-for-getting-person-id` は 5xx/タイムアウト時に指数バックオフで最大 3 回リトライ)。

---

## 6. データソース・運用上の注意

- 参照先は PostgreSQL の **`customer_info_production`** (検索用に `(name_kana, birth_ymd, cellular_phone_no)` の複合インデックスあり)。
- `customer_info_production` は ADF の CSV 取込パイプラインで **毎回入れ替え** られる参照専用データ (結果整合)。
- `name_kana` / `birth_ymd` / `cellular_phone_no` / `policy_no` は **個人情報 (PII)**。
- **本 Function は顧客 PII をログに出力しない**(確認済み):
  - ログは**静的メッセージのみ**(値を含まない。例: `logging.info("lookup person id by ...")`)。
  - 検索は**パラメータ化クエリ**(`%s` + 値別渡し)で、SQL 文字列にも値が入らない。
  - 400(`BAD_REQUEST`)の `message` は**項目名・汎用文言のみ**で入力値を含まない。
  - DB エラー時の `logging.exception` も**静的メッセージ + PII フリーのトレースバック**(Python のトレースバックはローカル変数値を含まず、
    パラメータ化クエリの psycopg 例外も値をエコーしない)。
- **例外: 5xx(`ERROR`)の `message` は DB 例外詳細(`str(exc)`)を AKS へ意図的に返す**(AKS 側の診断・リトライ判断のため)。
  これは **DB エラー詳細であって顧客 PII ではない**ため許容する。AKS 側でこの `message` をログに残す場合は DB 内部情報の取り扱いに留意すること。
- App Insights を将来接続してもリクエスト/レスポンスのボディは既定で非収集(URL に PII はなく、PII は POST ボディ側)。

---

## 7. 参考: 呼び出しクライアント実装

AKS 側の呼び出し例: `apps/aks/app-for-getting-person-id/main.py`
(Function キーをヘッダに付与し POST、`result_code` 分岐 + 5xx リトライの参考)。
