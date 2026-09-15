# Azure Functions (Python v2 モデル) ナレッジ

本リポジトリの Function は **Python v2 プログラミングモデル（デコレーター方式）**で実装している。
参考: https://learn.microsoft.com/ja-jp/azure/azure-functions/functions-reference-python?pivots=python-mode-decorators

## v1 と v2 の違い（要点）

| 観点 | v1（旧・本リポジトリの旧実装） | v2（現行） |
| --- | --- | --- |
| 関数定義 | 関数ごとにフォルダ + `function.json`（バインド定義）+ `__init__.py`（`def main(req)`） | `function_app.py` に**デコレーター**で定義。`function.json` 不要 |
| エントリ | フォルダ名＝関数名 | `function_app.py` の `app = func.FunctionApp()` |
| ルート/メソッド/認証 | `function.json` の `route` / `methods` / `authLevel` | `@app.route(route=..., methods=[...], auth_level=...)` |
| 分割 | フォルダ単位 | **Blueprint**（`func.Blueprint()`）を別ファイルに分け、`app.register_functions(bp)` で登録 |
| 依存 | 関数フォルダごと `requirements.txt` | **アプリ単位の単一** `requirements.txt`（`azure-functions>=1.11.2` 必須） |
| 必要設定 | 特になし | App 設定 `AzureWebJobsFeatureFlags=EnableWorkerIndexing`（v2 ワーカーインデックス） |

## ファイル構成（用途で分割）

```
terraform/envs/spoke-subscription/files/function_app/customer_search/src/
├── function_app.py     # エントリ。FunctionApp を作り Blueprint を登録するだけ
├── api.py              # 本人特定 API (POST /api/customers/search) を 1 ファイルに集約:
│                       #   Blueprint + ハンドラ + 正規化 + 検証 + 入力境界 + DB照合 + HTTP応答
├── database.py         # PostgreSQL 接続 (MSI/AAD トークンで DSN を組み立て)。connection_string()
├── host.json           # アプリ単位 (extensionBundle 4.x。v2 互換)
└── requirements.txt    # アプリ単位の単一依存
```

- **エントリ** `function_app.py`:
  ```python
  import azure.functions as func
  from api import bp as customer_search_bp
  app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
  app.register_functions(customer_search_bp)
  ```
- **本体** `api.py`（Blueprint + ハンドラ + 各層を 1 ファイルに集約。セクションコメントで区切る）:
  ```python
  bp = func.Blueprint()

  @bp.route(route="customers/search", methods=[func.HttpMethod.POST], auth_level=func.AuthLevel.FUNCTION)
  def search_customers(req):
      key, bad_request_message = parse_request(req)   # 入力検証・正規化
      if bad_request_message:
          return bad_request(bad_request_message)      # 400
      policy_no_list, db_error_detail = search(key)    # DB 照合
      if db_error_detail:
          return error(db_error_detail)                # 500
      return ok(policy_no_list)                        # 200 (MATCH / NOT_FOUND)
  ```
  関数: `normalize_name/phone/birth_date` / `validate_required/format` / `parse_request`（入力境界）/
  `search`（DB 照合。`from database import connection_string` を使用、失敗は詳細 str を返すだけ）/
  `_json_response`・`ok`・`bad_request`・`error`（HTTP 応答を一元管理）。
- **DB 接続** `database.py`: `connection_string()`（環境変数＋AAD トークン）。
- v2 のワーカーインデックスは `function_app.py` から推移的に import される blueprint を辿るため、`api.py` の
  `bp` が登録される（アプリルートが `sys.path` に載るので `from api import bp` / `from database import ...` が解決）。

## マッピング早見（v1 → v2）

| v1 (`function.json`) | v2 (デコレーター) |
| --- | --- |
| `"type":"httpTrigger"`, `"methods":["post"]`, `"route":"customers/search"` | `@bp.route(route="customers/search", methods=[func.HttpMethod.POST])` |
| `"authLevel":"function"` | `auth_level=func.AuthLevel.FUNCTION`（route or `FunctionApp(http_auth_level=...)`） |
| `def main(req)` + `"$return"` 出力バインド | デコレートした関数が `func.HttpResponse` を return |

## 認証・接続（変更なし）

- **AKS → Function**: Function キー方式（`auth_level=FUNCTION` → `x-functions-key` / `?code=`）。Easy Auth(AAD) は不使用。
- **Function → PostgreSQL**: Function の System-assigned マネージドID が取得した AAD トークンを
  psycopg の password に使う（`database.py`）。接続情報は環境変数
  `PSQL_HOST/PSQL_DATABASE/PSQL_USER/PSQL_PORT/PSQL_SSLMODE`。

## デプロイ

run-from-package（SCM 不使用・閉域）。`files/function_app/customer_search/src/` を依存込みで zip 化して配置 → `terraform apply`。
手順は [`terraform/envs/spoke-subscription/files/function_app/customer_search/README.md`](../terraform/envs/spoke-subscription/files/function_app/customer_search/README.md)。
v2 のため Function App に `AzureWebJobsFeatureFlags=EnableWorkerIndexing`（`function.tf`）が必要。

## ハマりどころ

- **`AzureWebJobsFeatureFlags=EnableWorkerIndexing` 未設定**だと、v2 のデコレーター関数が
  インデックスされず**関数が 1 つも認識されない**（404）。本リポジトリは `function.tf` で設定済み。
- `requirements.txt` の `azure-functions` が **1.11.2 未満**だと v2 モデルが動かない。
- `host.json` の `extensionBundle` は **4.x 系**（v2 互換）であること。
- Blueprint を `register_functions` し忘れるとそのルートが現れない。
- 機能追加時は「用途別 Blueprint を新ファイルで作成 → `function_app.py` で `register_functions`」。

## 関連

- API 仕様: [`api-customer-search.md`](./api-customer-search.md)
- 実コード: `terraform/envs/spoke-subscription/files/function_app/customer_search/src/`
