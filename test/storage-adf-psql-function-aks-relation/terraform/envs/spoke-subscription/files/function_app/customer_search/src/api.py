"""証券番号取得 API

URL : POST /api/customers/search
Auth: Function Key

Response:
    - 200 MATCH      : 照合成功 (1 件以上一致)
    - 200 NOT_FOUND  : 照合成功（該当なし）
    - 400 BAD_REQUEST: 入力不備 (欠落 / 形式不正)
    - 5xx ERROR      : DB 接続エラー / タイムアウト等
"""

from __future__ import annotations

import json
import logging
import re
import unicodedata
from typing import Any

import azure.functions as func
import psycopg

from database import connection_string

bp = func.Blueprint()

# 検索キー (正規化済みの 3 項目: name_kana, birth_ymd, cellular_phone_no)
SearchKey = tuple[str, str, str]


# ============================================================================
# 正規化 (表記揺れ吸収)
# ============================================================================
_WHITESPACE_RE = re.compile(r"\s+")
_DASH_CHARS = ("‐", "‑", "‒", "–", "—", "―", "−", "ー", "－")


# 氏名: NFKC で全角へ寄せ、姓名間の空白を ADF 格納形と同じ全角スペース(U+3000) 1 個へ正規化
# (customer_info_production は ADF が `姓＜全角スペース＞名` で格納するため、完全一致照合に揃える)
def normalize_name(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).strip()
    return _WHITESPACE_RE.sub("　", normalized)


# 電話番号: NFKC で全角→半角、空白除去、各種ダッシュを ASCII ハイフンへ統一
def normalize_phone(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).replace(" ", "")
    for dash in _DASH_CHARS:
        normalized = normalized.replace(dash, "-")
    return normalized


# 生年月日: 全角数字を半角へ寄せ前後空白を除去
def normalize_birth_date(value: str) -> str:
    return unicodedata.normalize("NFKC", value).strip()


# ============================================================================
# バリデーション (エラーメッセージ str を返却、問題なければ None)
# ============================================================================
REQUIRED_FIELDS = ("name_kana", "birth_ymd", "cellular_phone_no")
_BIRTH_YMD_RE = re.compile(r"^[0-9]{8}$")
_PHONE_RE = re.compile(r"^[0-9]{2,4}-[0-9]{2,4}-[0-9]{4}$")
_NAME_MAX = 50  # name_kana の業務上限 (全角カナ 50 文字)


def validate_required(body: dict[str, Any]) -> str | None:
    missing = [f for f in REQUIRED_FIELDS if not body.get(f)]
    if missing:
        return f"入力パラメータが不足しています: {', '.join(missing)}"
    return None


def validate_format(name_kana: str, birth_ymd: str, cellular_phone_no: str) -> str | None:
    if not name_kana or len(name_kana) > _NAME_MAX:
        return "入力パラメータの形式が不正です。(name_kana は全角カナ 50 文字以内)"
    if not _BIRTH_YMD_RE.match(birth_ymd):
        return "入力パラメータの形式が不正です。(birth_ymd は YYYYMMDD)"
    if not _PHONE_RE.match(cellular_phone_no):
        return "入力パラメータの形式が不正です。(cellular_phone_no は XXX-XXXX-XXXX)"
    return None


# ============================================================================
# 入力境界 (リクエスト → 検索キー)
# 成功 (key, None) / 不備 (None, メッセージ)
# ============================================================================
def parse_request(req: func.HttpRequest) -> tuple[SearchKey | None, str | None]:
    try:
        body = req.get_json()
    except ValueError:
        return None, "リクエストボディが不正な JSON です。"

    if not isinstance(body, dict):
        return None, "リクエストボディは JSON オブジェクトである必要があります。"

    required_error = validate_required(body)
    if required_error:
        return None, required_error

    name_kana = normalize_name(str(body["name_kana"]))
    birth_ymd = normalize_birth_date(str(body["birth_ymd"]))
    cellular_phone_no = normalize_phone(str(body["cellular_phone_no"]))

    format_error = validate_format(name_kana, birth_ymd, cellular_phone_no)
    if format_error:
        return None, format_error

    return (name_kana, birth_ymd, cellular_phone_no), None


# ============================================================================
# DB 照合
# 成功 (policy_no_list, None) / 失敗 (None, 例外詳細 str)
# ============================================================================
def search(key: SearchKey) -> tuple[list[str] | None, str | None]:
    name_kana, birth_ymd, cellular_phone_no = key
    sql = (
        "SELECT policy_no "
        "FROM customer_info_production "
        "WHERE name_kana = %s AND birth_ymd = %s AND cellular_phone_no = %s "
        "ORDER BY policy_no"
    )
    try:
        with psycopg.connect(connection_string()) as conn:
            with conn.cursor() as cur:
                cur.execute(sql, [name_kana, birth_ymd, cellular_phone_no])
                policy_no_list = [row[0] for row in cur.fetchall()]
                logging.info("lookup person id by name_kana/birth_ymd/cellular_phone_no")
                return policy_no_list, None
    except Exception as exc:  # noqa: BLE001 - 接続/クエリ失敗を 500 として扱う
        logging.exception("failed to query customer_info_production")
        return None, str(exc)


# ============================================================================
# HTTP 応答 (200/400/500 を一元管理)
# ============================================================================
def _json_response(status_code: int, payload: dict[str, Any]) -> func.HttpResponse:
    return func.HttpResponse(
        body=json.dumps(payload, ensure_ascii=False),
        status_code=status_code,
        mimetype="application/json",
    )


def status_ok(policy_no_list: list[str]) -> func.HttpResponse:
    if policy_no_list:
        return _json_response(200, {"result_code": "MATCH", "policy_no": policy_no_list})
    return _json_response(200, {"result_code": "NOT_FOUND", "policy_no": []})


def status_bad_request(message: str) -> func.HttpResponse:
    return _json_response(400, {"result_code": "BAD_REQUEST", "message": message})


def status_server_error(detail: str) -> func.HttpResponse:
    return _json_response(500, {"result_code": "ERROR", "message": detail})


# ============================================================================
# ハンドラ (parse → search → respond を統括)
# ============================================================================
@bp.route(route="customers/search", methods=[func.HttpMethod.POST], auth_level=func.AuthLevel.FUNCTION)
def search_customers(req: func.HttpRequest) -> func.HttpResponse:
    key, bad_request_message = parse_request(req)
    if bad_request_message:
        return status_bad_request(bad_request_message)

    policy_no_list, db_error_detail = search(key)
    if db_error_detail:
        return status_server_error(db_error_detail)

    return status_ok(policy_no_list)
