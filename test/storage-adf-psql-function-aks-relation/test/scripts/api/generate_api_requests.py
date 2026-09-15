"""手動テスト (経路2: Function API へのリクエスト投入) 用の JSON を生成するスクリプト。

`POST /api/customers/search` (実装: terraform/.../function_app/customer_search/src/api.py) の
成功パターン・失敗パターンを 1 ケース = 1 ファイルで出力し、あわせて期待値付きの
ケース一覧 `cases.json` を出力する。出力した JSON は **NW 疎通可能な VM から curl で
パス指定して投げる** (`curl -d @<file>`)。手順は test/02-function-api.md を参照。

出力 (既定 test/data/api-requests):
    <case_id>.json  : リクエストボディ (壊れた JSON 等の異常系は .txt でそのまま出力)
    cases.json      : 全ケースの定義 + 期待値 (期待値表・突合の元データ)

前提データ:
    検索キーは `scenario_known_person.csv` を Storage に投入して
    `customer_info_production` に入っている状態を前提とする
    (生成: test/scripts/csv/generate_scenario_csv.py)。
    値を変えた場合は下記 KNOWN_* と CSV 側の両方を合わせること。

使い方:
    python test/scripts/api/generate_api_requests.py --out-dir test/data/api-requests
"""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import dataclass, field
from typing import Any

# ----------------------------------------------------------------------------
# 前提データ (scenario_known_person.csv と一致させること)
# ----------------------------------------------------------------------------
MULTI = ("タナカ　タロウ", "19900101", "090-1111-2222")          # policy_no 3 件ヒット
MULTI_POLICY_NO = ["0000000001", "0000000002", "0000000003"]
SINGLE = ("スズキ　ハナコ", "19851215", "080-3333-4444")         # policy_no 1 件ヒット
SINGLE_POLICY_NO = ["0000000004"]
BOUNDARY_NAME = "ア" * 24 + "　" + "イ" * 25                     # ちょうど 50 文字
BOUNDARY = (BOUNDARY_NAME, "20240229", "090-0000-0001")
BOUNDARY_POLICY_NO = ["AB12345678"]

NAME_51 = "ア" * 25 + "　" + "イ" * 25                            # 51 文字 (上限超過)

REQUIRED_FIELDS = ("name_kana", "birth_ymd", "cellular_phone_no")


@dataclass(frozen=True)
class Case:
    """API テストケース 1 件。

    Attributes:
        case_id: 表と突合するための ID (F-xx = Function 直叩き / K-xx = AKS 経由固有)。
        title: 何を確かめるか。
        body: JSON ボディ (dict)。raw を使う場合は None。
        raw: 生のリクエストボディ (壊れた JSON / 非オブジェクト等)。
        auth: valid=正しいキー / missing=キー無し / invalid=不正キー / query=?code= で渡す。
        method: HTTP メソッド。
        path: 既定 (/api/customers/search) 以外を叩く場合のパス。
        content_type: 既定 application/json 以外を送る場合。
        expect: 直叩き時の期待値 {status, result_code, policy_no, message_contains}。
        via_aks: AKS 経由 (form) 時の期待値。None なら body から自動導出。
        note: 補足 (表の「備考」列)。
    """

    case_id: str
    title: str
    expect: dict[str, Any]
    body: dict[str, Any] | None = None
    raw: str | None = None
    auth: str = "valid"
    method: str = "POST"
    path: str | None = None
    content_type: str | None = None
    via_aks: dict[str, Any] | None = None
    note: str = ""
    category: str = ""
    extra: dict[str, Any] = field(default_factory=dict)


def _body(name_kana: str, birth_ymd: str, cellular_phone_no: str) -> dict[str, Any]:
    """3 項目そろったリクエストボディを組み立てる。"""
    return {"name_kana": name_kana, "birth_ymd": birth_ymd, "cellular_phone_no": cellular_phone_no}


def _match(policy_no: list[str]) -> dict[str, Any]:
    return {"status": 200, "result_code": "MATCH", "policy_no": policy_no}


NOT_FOUND: dict[str, Any] = {"status": 200, "result_code": "NOT_FOUND", "policy_no": []}


def _bad_request(message_contains: str) -> dict[str, Any]:
    return {"status": 400, "result_code": "BAD_REQUEST", "message_contains": message_contains}


# ============================================================================
# ケース定義 (test/02-function-api.md の表と 1:1)
# ============================================================================
def _cases() -> list[Case]:
    """全ケースを返す。"""
    return [
        # --------------------------------------------------------------
        # A. 成功 (200 MATCH)
        # --------------------------------------------------------------
        Case("F-A01", "完全一致 1 件", _match(SINGLE_POLICY_NO), _body(*SINGLE), category="success"),
        Case("F-A02", "同一人物が複数 policy_no を持つ (配列・policy_no 昇順)",
             _match(MULTI_POLICY_NO), _body(*MULTI), category="success"),
        Case("F-A03", "姓名の区切りが半角スペース (正規化で全角へ)",
             _match(MULTI_POLICY_NO), _body("タナカ タロウ", MULTI[1], MULTI[2]), category="success",
             note="normalize_name: strip + 連続空白 -> U+3000 1 個"),
        Case("F-A04", "前後・連続空白入り", _match(MULTI_POLICY_NO),
             _body("  タナカ   タロウ  ", MULTI[1], MULTI[2]), category="success"),
        Case("F-A05", "氏名が半角カナ (NFKC で全角化)", _match(MULTI_POLICY_NO),
             _body("ﾀﾅｶ ﾀﾛｳ", MULTI[1], MULTI[2]), category="success"),
        Case("F-A06", "生年月日が全角数字", _match(MULTI_POLICY_NO),
             _body(MULTI[0], "１９９００１０１", MULTI[2]), category="success"),
        Case("F-A07", "電話が全角数字 + 長音記号区切り", _match(MULTI_POLICY_NO),
             _body(MULTI[0], MULTI[1], "０９０ー１１１１ー２２２２"), category="success",
             note="normalize_phone: NFKC + ダッシュ類 -> ASCII ハイフン"),
        Case("F-A08", "電話に空白混じり", _match(MULTI_POLICY_NO),
             _body(MULTI[0], MULTI[1], "090 - 1111 - 2222"), category="success"),
        Case("F-A09", "電話が全角ハイフン", _match(MULTI_POLICY_NO),
             _body(MULTI[0], MULTI[1], "０９０－１１１１－２２２２"), category="success"),
        Case("F-A10", "境界値 (氏名ちょうど 50 文字 / 閏日 20240229)",
             _match(BOUNDARY_POLICY_NO), _body(*BOUNDARY), category="success"),
        Case("F-A11", "値が数値型 (str() で文字列化される)", _match(MULTI_POLICY_NO),
             {"name_kana": MULTI[0], "birth_ymd": 19900101, "cellular_phone_no": MULTI[2]},
             category="success", note="JSON の型は問わない。19900101 -> '19900101'"),
        Case("F-A12", "未知のキーを含む (無視される)", _match(SINGLE_POLICY_NO),
             {**_body(*SINGLE), "policy_no": "9999999999", "extra": True}, category="success"),
        Case("F-A13", "キーをクエリ ?code= で渡す", _match(SINGLE_POLICY_NO), _body(*SINGLE),
             auth="query", category="success", via_aks={"skip": "AKS 経由ではキー付与はアプリ側が行う"}),

        # --------------------------------------------------------------
        # B. 照合成功・該当なし (200 NOT_FOUND)
        # --------------------------------------------------------------
        Case("F-B01", "存在しない人", NOT_FOUND, _body("ナイ　ヒト", "20201231", "000-0000-0000"),
             category="not_found"),
        Case("F-B02", "氏名・生年月日は一致するが電話だけ違う (3 項目 AND)", NOT_FOUND,
             _body(MULTI[0], MULTI[1], "090-9999-9999"), category="not_found"),
        Case("F-B03", "姓名の区切りが無い", NOT_FOUND, _body("タナカタロウ", MULTI[1], MULTI[2]),
             category="not_found", note="正規化は区切りを補わない。DB は 姓＜U+3000＞名 で格納"),
        Case("F-B04", "氏名がカタカナでない (英字)", NOT_FOUND, _body("tanaka taro", MULTI[1], MULTI[2]),
             category="not_found", note="Function は文字種を検証しない (長さのみ)。文字種検証は SQL 側だけ"),
        Case("F-B05", "実在しない日付 20260230", NOT_FOUND, _body(MULTI[0], "20260230", MULTI[2]),
             category="not_found", note="Function は 8 桁数字のみ判定。実在日検証は SQL 側だけ"),
        Case("F-B06", "電話が 2-4-4 (03-1111-2222)", NOT_FOUND, _body(MULTI[0], MULTI[1], "03-1111-2222"),
             category="not_found",
             note="実装の正規表現は ^[0-9]{2,4}-[0-9]{2,4}-[0-9]{4}$ で仕様書 (3-4-4) より緩い"),

        # --------------------------------------------------------------
        # C. 入力不備 (400 BAD_REQUEST)
        # --------------------------------------------------------------
        Case("F-C01", "name_kana 欠落", _bad_request("不足しています: name_kana"),
             {"birth_ymd": MULTI[1], "cellular_phone_no": MULTI[2]}, category="bad_request"),
        Case("F-C02", "3 項目すべて欠落",
             _bad_request("不足しています: name_kana, birth_ymd, cellular_phone_no"), {},
             category="bad_request"),
        Case("F-C03", "birth_ymd が空文字 (欠落と同じ扱い)", _bad_request("不足しています: birth_ymd"),
             _body(MULTI[0], "", MULTI[2]), category="bad_request",
             note="空文字は falsy のため必須チェックで弾かれる"),
        Case("F-C04", "cellular_phone_no が null", _bad_request("不足しています: cellular_phone_no"),
             {"name_kana": MULTI[0], "birth_ymd": MULTI[1], "cellular_phone_no": None},
             category="bad_request", note="form では null を送れないため AKS 経由では空文字 = 422 になる"),
        Case("F-C05", "name_kana 51 文字", _bad_request("name_kana は全角カナ 50 文字以内"),
             _body(NAME_51, MULTI[1], MULTI[2]), category="bad_request"),
        Case("F-C06", "birth_ymd 7 桁", _bad_request("birth_ymd は YYYYMMDD"),
             _body(MULTI[0], "1990010", MULTI[2]), category="bad_request"),
        Case("F-C07", "birth_ymd が 8 文字だが非数字", _bad_request("birth_ymd は YYYYMMDD"),
             _body(MULTI[0], "1990/1/1", MULTI[2]), category="bad_request"),
        Case("F-C08", "電話ハイフン無し", _bad_request("cellular_phone_no は XXX-XXXX-XXXX"),
             _body(MULTI[0], MULTI[1], "09011112222"), category="bad_request"),
        Case("F-C09", "電話が 3-4-3 (末尾 3 桁)", _bad_request("cellular_phone_no は XXX-XXXX-XXXX"),
             _body(MULTI[0], MULTI[1], "090-1111-222"), category="bad_request"),
        Case("F-C10", "電話の先頭が 5 桁", _bad_request("cellular_phone_no は XXX-XXXX-XXXX"),
             _body(MULTI[0], MULTI[1], "09012-1111-2222"), category="bad_request"),
        Case("F-C11", "壊れた JSON", _bad_request("不正な JSON"), raw='{"name_kana":',
             category="bad_request", via_aks={"skip": "form では表現できない"}),
        Case("F-C12", "ボディが空", _bad_request("不正な JSON"), raw="",
             category="bad_request", via_aks={"skip": "form では表現できない"}),
        Case("F-C13", "ボディが JSON 配列", _bad_request("JSON オブジェクトである必要"), raw="[]",
             category="bad_request", via_aks={"skip": "form では表現できない"}),
        Case("F-C14", "ボディが JSON 文字列", _bad_request("JSON オブジェクトである必要"), raw='"abc"',
             category="bad_request", via_aks={"skip": "form では表現できない"}),
        Case("F-C15", "form 形式で直叩き (JSON でない)", _bad_request("不正な JSON"),
             raw="name_kana=%E3%82%BF%E3%83%8A%E3%82%AB&birth_ymd=19900101",
             content_type="application/x-www-form-urlencoded", category="bad_request",
             via_aks={"skip": "AKS 経由は form が正しい送り方"},
             note="Function は Content-Type を見ずに JSON パースする"),

        # --------------------------------------------------------------
        # D. プラットフォーム層 (result_code を含まない)
        # --------------------------------------------------------------
        Case("F-D01", "Function キー無し", {"status": 401}, _body(*SINGLE), auth="missing",
             category="platform", via_aks={"skip": "キー付与は AKS アプリの責務"}),
        Case("F-D02", "Function キーが不正", {"status": 401}, _body(*SINGLE), auth="invalid",
             category="platform", via_aks={"skip": "キー付与は AKS アプリの責務"}),
        Case("F-D03", "GET メソッド (ルートは POST のみ)", {"status": 404}, method="GET",
             category="platform", via_aks={"skip": "AKS 側は別ルート"},
             note="Functions ホストがルート不一致として返す"),
        Case("F-D04", "存在しないパス", {"status": 404}, _body(*SINGLE),
             path="/api/customers/searchx", category="platform",
             via_aks={"skip": "AKS 側は 404 (FastAPI)"}),
    ]


def _auto_via_aks(case: Case) -> dict[str, Any]:
    """AKS 経由 (form) の期待値を body から導出する。

    直叩きと**層が違う**ため期待値がずれる点が 2 つある (どちらもローカル再現で確認済み):

    - 欠落 / 空文字の項目は FastAPI の `Form(...)` が「欠落」と判定し **422**。
      Function には届かないので `result_code` は返らない。
    - AKS の中継 API (`main.py`) は Function のレスポンス JSON を**そのまま return** するため、
      FastAPI が付ける HTTP ステータスは常に **200**。Function の 400 は
      `200 + result_code=BAD_REQUEST` として観測される。
    """
    if case.via_aks is not None:
        return case.via_aks
    if case.body is None:
        return {"skip": "form では表現できない"}
    if any(field_name not in case.body for field_name in REQUIRED_FIELDS):
        return {"status": 422, "note": "FastAPI の Form(...) 必須チェック (Function には届かない)"}
    if any(case.body[field_name] in ("", None) for field_name in REQUIRED_FIELDS):
        return {"status": 422, "note": "空文字の form 値は FastAPI が欠落 (missing) と判定する"}
    if case.expect.get("status") == 400:
        return {
            "status": 200,
            "result_code": "BAD_REQUEST",
            "message_contains": case.expect.get("message_contains"),
            "note": "中継 API は Function の HTTP ステータスを引き継がない (常に 200 + result_code)",
        }
    return dict(case.expect)


def _write_body(case: Case, out_dir: str) -> str:
    """リクエストボディを個別ファイルへ書き出し、ファイル名を返す (curl -d @ で使える)。

    ボディを持たないケース (GET 等) はファイルを作らない。
    """
    if case.body is None and case.raw is None:
        return "-"
    name = f"{case.case_id}.json" if case.raw is None else f"{case.case_id}.txt"
    path = os.path.join(out_dir, name)
    with open(path, "w", encoding="utf-8", newline="\n") as fp:
        if case.raw is not None:
            fp.write(case.raw)
        else:
            json.dump(case.body, fp, ensure_ascii=False)
    return name


def _serialize(case: Case, file_name: str) -> dict[str, Any]:
    """cases.json に載せる 1 ケース分の辞書を返す。"""
    return {
        "id": case.case_id,
        "title": case.title,
        "category": case.category,
        "file": file_name,
        "request": {
            "method": case.method,
            "path": case.path or "/api/customers/search",
            "auth": case.auth,
            "content_type": case.content_type or "application/json",
            "body": case.body,
            "raw": case.raw,
        },
        "expect": case.expect,
        "expect_via_aks": _auto_via_aks(case),
        "note": case.note,
    }


def _parse_args() -> str:
    parser = argparse.ArgumentParser(description="Function API テスト用のリクエスト JSON を生成する")
    parser.add_argument("--out-dir", type=str, default="test/data/api-requests", help="出力ディレクトリ")
    return parser.parse_args().out_dir


def main() -> None:
    """エントリポイント。個別 JSON と cases.json を出力する。"""
    out_dir = _parse_args()
    os.makedirs(out_dir, exist_ok=True)

    cases = _cases()
    serialized = [_serialize(case, _write_body(case, out_dir)) for case in cases]

    cases_path = os.path.join(out_dir, "cases.json")
    with open(cases_path, "w", encoding="utf-8", newline="\n") as fp:
        json.dump({"cases": serialized}, fp, ensure_ascii=False, indent=2)
        fp.write("\n")

    print(f"generated {len(cases)} cases -> {os.path.abspath(out_dir)}")
    for case, body in zip(cases, serialized):
        expect = case.expect
        summary = f"{expect.get('status')} {expect.get('result_code') or ''}".strip()
        print(f"  {case.case_id:<7} {summary:<16} {case.title}  ({body['file']})")


if __name__ == "__main__":
    main()
