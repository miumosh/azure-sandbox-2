"""生成済みケース (cases.json) を実際に投げて、期待値と突合するテストランナー。

2 つの経路をモードで切り替える:

    --mode direct : Function を直叩き (JSON + x-functions-key)。
                    Function は Private Endpoint 専用で、到達できるのは
                    **AKS サブネットのみ** (snet-pe-func-nsg)。したがって
                    AKS Pod の中から実行すること (invoke-api-cases.sh が面倒を見る)。
    --mode aks    : AKS の person-id-app 公開 IP へ form で投げる (FastAPI 層込みの E2E)。
                    ローカル端末から実行できる。

標準ライブラリのみで動作する (person-id-app のイメージにそのまま流し込めるようにするため)。

使い方:
    # AKS 経由 (ローカルから)
    python run_api_cases.py --mode aks --base-url http://<AKS_PUBLIC_IP> --cases ./api-requests/cases.json

    # Function 直叩き (Pod の中から。base-url/key は Pod の環境変数を既定で使う)
    python run_api_cases.py --mode direct --cases /tmp/cases.json
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

REQUEST_PATH = "/api/customers/search"


# ============================================================================
# リクエスト送信
# ============================================================================
def _build_request(case: dict[str, Any], mode: str, base_url: str, key: str) -> urllib.request.Request:
    """ケース定義から HTTP リクエストを組み立てる。"""
    request_spec = case["request"]
    method = request_spec["method"]
    headers: dict[str, str] = {}

    if mode == "aks":
        # AKS の person-id-app は form (multipart/urlencoded) で受ける。キー付与はアプリ側の責務。
        url = base_url.rstrip("/") + REQUEST_PATH
        body = request_spec["body"] or {}
        data = urllib.parse.urlencode({k: "" if v is None else str(v) for k, v in body.items()}).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    else:
        url = base_url.rstrip("/") + request_spec["path"]
        auth = request_spec["auth"]
        if auth == "valid":
            headers["x-functions-key"] = key
        elif auth == "invalid":
            headers["x-functions-key"] = "invalid-key-0000000000000000"
        elif auth == "query":
            url = f"{url}?code={urllib.parse.quote(key)}"
        # auth == "missing" はヘッダを付けない

        raw = request_spec["raw"]
        if raw is not None:
            data = raw.encode("utf-8")
        elif request_spec["body"] is not None:
            data = json.dumps(request_spec["body"], ensure_ascii=False).encode("utf-8")
        else:
            data = None
        if data is not None:
            headers["Content-Type"] = request_spec["content_type"]

    if method == "GET":
        data = None
    return urllib.request.Request(url, data=data, headers=headers, method=method)


def _send(request: urllib.request.Request, timeout: float) -> tuple[int, Any, str]:
    """リクエストを送り (status, パース済み JSON or None, 生テキスト) を返す。"""
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status, text = response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:  # 4xx/5xx もレスポンスとして評価する
        status, text = exc.code, exc.read().decode("utf-8", "replace")
    except Exception as exc:  # 接続不可・タイムアウト等はケース失敗として扱う
        return 0, None, f"{type(exc).__name__}: {exc}"

    try:
        return status, json.loads(text), text
    except ValueError:
        return status, None, text


# ============================================================================
# 期待値との突合
# ============================================================================
def _judge(expect: dict[str, Any], status: int, payload: Any, text: str) -> tuple[bool, str]:
    """期待値と実測を比較し (合否, 不一致の理由) を返す。"""
    if expect.get("status") is not None and status != expect["status"]:
        return False, f"status {status} != {expect['status']}"

    if expect.get("result_code") is not None:
        actual = payload.get("result_code") if isinstance(payload, dict) else None
        if actual != expect["result_code"]:
            return False, f"result_code {actual!r} != {expect['result_code']!r}"

    if expect.get("policy_no") is not None:
        actual = payload.get("policy_no") if isinstance(payload, dict) else None
        if actual != expect["policy_no"]:
            return False, f"policy_no {actual!r} != {expect['policy_no']!r}"

    if expect.get("message_contains"):
        message = payload.get("message", "") if isinstance(payload, dict) else text
        if expect["message_contains"] not in str(message):
            return False, f"message に {expect['message_contains']!r} を含まない: {str(message)[:80]!r}"

    return True, ""


def _summarize(status: int, payload: Any, text: str) -> str:
    """実測結果を 1 行に要約する。"""
    if isinstance(payload, dict):
        code = payload.get("result_code")
        if code == "MATCH":
            return f"{status} MATCH {payload.get('policy_no')}"
        if code:
            detail = str(payload.get("message", ""))[:40]
            return f"{status} {code} {detail}".strip()
        return f"{status} {json.dumps(payload, ensure_ascii=False)[:60]}"
    return f"{status} {text[:60]!r}" if status else text[:80]


def _expected_label(expect: dict[str, Any]) -> str:
    """期待値を 1 行に要約する。"""
    if "skip" in expect:
        return "skip"
    parts = [str(expect.get("status", "-"))]
    if expect.get("result_code"):
        parts.append(expect["result_code"])
    if expect.get("policy_no"):
        parts.append(str(expect["policy_no"]))
    if expect.get("message_contains"):
        parts.append(f"~{expect['message_contains']}")
    return " ".join(parts)


# ============================================================================
# エントリポイント
# ============================================================================
def _load_cases(args: argparse.Namespace) -> list[dict[str, Any]]:
    """cases.json を --cases (パス) か --cases-b64 (base64 文字列) から読む。"""
    if args.cases_b64:
        document = json.loads(base64.b64decode(args.cases_b64).decode("utf-8"))
    else:
        with open(args.cases, encoding="utf-8") as fp:
            document = json.load(fp)
    cases = document["cases"]
    if args.only:
        wanted = set(args.only)
        cases = [c for c in cases if c["id"] in wanted]
    return cases


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Function API のテストケースを実行して期待値と突合する")
    parser.add_argument("--mode", choices=("direct", "aks"), default="direct",
                        help="direct=Function 直叩き (Pod 内) / aks=AKS 公開 IP 経由")
    parser.add_argument("--cases", default="./api-requests/cases.json", help="cases.json のパス")
    parser.add_argument("--cases-b64", default=None, help="cases.json を base64 で直接渡す (Pod 実行用)")
    parser.add_argument("--base-url", default=os.environ.get("FUNCTIONS_BASE_URL", ""),
                        help="direct: Function のベース URL / aks: http://<AKS_PUBLIC_IP>")
    parser.add_argument("--key", default=os.environ.get("FUNCTIONS_KEY", ""), help="Function キー (direct のみ)")
    parser.add_argument("--only", nargs="*", default=None, help="実行するケース ID (未指定なら全件)")
    parser.add_argument("--timeout", type=float, default=30.0, help="1 リクエストのタイムアウト秒")
    return parser.parse_args()


def main() -> None:
    """全ケースを実行し、結果表とサマリを表示する (失敗があれば exit 1)。"""
    args = _parse_args()
    if not args.base_url:
        sys.exit("--base-url (または環境変数 FUNCTIONS_BASE_URL) を指定してください")
    if args.mode == "direct" and not args.key:
        sys.exit("--key (または環境変数 FUNCTIONS_KEY) を指定してください")

    cases = _load_cases(args)
    print(f"mode={args.mode}  base_url={args.base_url}  cases={len(cases)}\n")
    print(f"{'ID':<7} {'判定':<6} {'期待':<44} 実測")
    print("-" * 120)

    passed = failed = skipped = 0
    failures: list[tuple[str, str]] = []

    for case in cases:
        expect = case["expect_via_aks"] if args.mode == "aks" else case["expect"]
        if "skip" in expect:
            skipped += 1
            print(f"{case['id']:<7} {'SKIP':<6} {expect['skip']}")
            continue

        status, payload, text = _send(_build_request(case, args.mode, args.base_url, args.key), args.timeout)
        ok, reason = _judge(expect, status, payload, text)
        passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
        if not ok:
            failures.append((case["id"], reason))
        print(f"{case['id']:<7} {'PASS' if ok else 'FAIL':<6} {_expected_label(expect):<44} {_summarize(status, payload, text)}")

    print("-" * 120)
    print(f"PASS={passed}  FAIL={failed}  SKIP={skipped}")
    for case_id, reason in failures:
        print(f"  FAIL {case_id}: {reason}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
