"""AKS 上で動作する本人特定クライアントアプリ (フロント + バックエンド一体型)。

概要:
    - Azure Functions の本人特定 API (POST /api/customers/search) へリクエストを送り、
      name_kana + birth_ymd + cellular_phone_no に一致する policy_no を取得して表示する。
    - フロント / バックエンドともに Python (FastAPI) で実装する。
    - Functions へはプライベートエンドポイント経由で接続する
      (privatelink DNS が VNet 内で解決される前提)。

Function のレスポンス契約 (result_code):
    - 200 {"result_code":"MATCH","policy_no":[...]}      照合成功 (該当あり)
    - 200 {"result_code":"NOT_FOUND","policy_no":[]}     照合成功 (該当なし)
    - 400 {"result_code":"BAD_REQUEST","message"} 入力不備
    - 5xx {"result_code":"ERROR","message"}       DB エラー/タイムアウト -> 本アプリでリトライ

認証:
    AKS -> Function は Function キー方式。環境変数 FUNCTIONS_KEY の関数キーを
    x-functions-key ヘッダに付与して呼び出す (AAD / Workload Identity は不使用)。

必要な環境変数:
    FUNCTIONS_BASE_URL : Azure Functions のベース URL
                         (例: https://ci00-func.azurewebsites.net)
    FUNCTIONS_KEY      : Function キー (x-functions-key ヘッダに付与)
"""

from __future__ import annotations

import asyncio
import html
import os
from typing import Any

import httpx
from fastapi import FastAPI, Form
from fastapi.responses import HTMLResponse, JSONResponse

app = FastAPI(title="Person ID Lookup App")

# Functions 側のルート (api/handler.py の route="customers/search" に対応)
_PERSON_ID_ROUTE = "/api/customers/search"

# 5xx / タイムアウト時のリトライ設定 (DB 一時障害を吸収する)
_MAX_ATTEMPTS = 3
_RETRY_BACKOFF_SEC = 0.5


def _functions_base_url() -> str:
    """Azure Functions のベース URL を環境変数から取得する。"""
    return os.environ["FUNCTIONS_BASE_URL"].rstrip("/")


def _build_headers() -> dict[str, str]:
    """Function キーを含むリクエストヘッダを生成する。"""
    return {"x-functions-key": os.environ["FUNCTIONS_KEY"]}


async def _lookup_ids(name_kana: str, birth_ymd: str, cellular_phone_no: str) -> dict[str, Any]:
    """Functions の /api/customers/search を呼び出して result_code 付き JSON を取得する。

    5xx / タイムアウトは一時障害とみなし、指数バックオフで最大 _MAX_ATTEMPTS 回リトライする。
    400 (BAD_REQUEST) は入力不備のためリトライせずそのまま返す。
    """
    body = {"name_kana": name_kana, "birth_ymd": birth_ymd, "cellular_phone_no": cellular_phone_no}
    url = f"{_functions_base_url()}{_PERSON_ID_ROUTE}"

    last_exc: Exception | None = None
    for attempt in range(1, _MAX_ATTEMPTS + 1):
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                res = await client.post(url, json=body, headers=_build_headers())
            if res.status_code >= 500:
                # DB エラー/タイムアウト等 -> リトライ対象
                last_exc = httpx.HTTPStatusError(
                    f"server error {res.status_code}", request=res.request, response=res
                )
            else:
                # 200 (MATCH/NOT_FOUND) / 400 (BAD_REQUEST) はそのまま返す
                return res.json()
        except (httpx.TimeoutException, httpx.TransportError) as exc:
            last_exc = exc

        if attempt < _MAX_ATTEMPTS:
            await asyncio.sleep(_RETRY_BACKOFF_SEC * attempt)

    # リトライ上限到達: 呼び出し側へ ERROR を返す
    return {"result_code": "ERROR", "message": f"function call failed: {last_exc}"}


def _render_page(result: dict[str, Any] | None) -> str:
    """検索フォームと結果 (result_code + policy_no 一覧) を HTML で描画する。"""
    result_html = ""
    if result is not None:
        code = str(result.get("result_code", ""))
        ids: list[str] = result.get("policy_no", [])
        message = result.get("message")
        if code == "MATCH":
            items = "".join(f"<li>{html.escape(str(i))}</li>" for i in ids)
            body = f"<ul>{items}</ul>"
        elif code == "NOT_FOUND":
            body = "<p>該当する policy_no はありません。</p>"
        else:  # BAD_REQUEST / ERROR
            body = f"<p>{html.escape(str(message or ''))}</p>"
        result_html = f"""
  <h2>結果</h2>
  <p>result_code = <code>{html.escape(code)}</code></p>
  {body}"""

    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8" />
  <title>person id lookup</title>
  <style>
    body {{ font-family: -apple-system, 'Segoe UI', sans-serif; margin: 24px; }}
    label {{ display: block; margin-bottom: 8px; }}
    input {{ margin-left: 8px; }}
  </style>
</head>
<body>
  <h1>本人特定 (policy_no 取得)</h1>
  <form method="post" action="/">
    <label>name_kana (全角カナ):
      <input type="text" name="name_kana" maxlength="50" required />
    </label>
    <label>birth_ymd (YYYYMMDD):
      <input type="text" name="birth_ymd" maxlength="8" required />
    </label>
    <label>cellular_phone_no (XXX-XXXX-XXXX):
      <input type="text" name="cellular_phone_no" maxlength="15" required />
    </label>
    <button type="submit">policy_no を取得</button>
  </form>{result_html}
</body>
</html>"""


@app.get("/health", response_class=JSONResponse)
def health() -> dict[str, str]:
    """Kubernetes の liveness / readiness 用ヘルスチェック。"""
    return {"status": "ok"}


@app.post("/api/customers/search", response_class=JSONResponse)
async def api_person_id(
    name_kana: str = Form(...),
    birth_ymd: str = Form(...),
    cellular_phone_no: str = Form(...),
) -> dict[str, Any]:
    """Functions の /api/customers/search を中継する JSON API (result_code をそのまま返す)。"""
    return await _lookup_ids(name_kana, birth_ymd, cellular_phone_no)


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    """トップページ: 本人特定の検索フォームを表示する。"""
    return HTMLResponse(content=_render_page(None))


@app.post("/", response_class=HTMLResponse)
async def index_post(
    name_kana: str = Form(...),
    birth_ymd: str = Form(...),
    cellular_phone_no: str = Form(...),
) -> HTMLResponse:
    """フォーム送信: Functions で policy_no を引いて結果を表示する。"""
    result = await _lookup_ids(name_kana, birth_ymd, cellular_phone_no)
    return HTMLResponse(content=_render_page(result))
