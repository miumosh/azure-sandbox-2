"""`validation.sql` の判定をローカルで再現し、CSV 投入前に期待値を確定するシミュレータ。

成果物 Storage / PostgreSQL は完全閉域のため、ローカルから `customer_info_error` の
`error_message` を直接読むことはできない。本スクリプトは
`terraform/envs/hub-subscription/files/adf_pipeline/customer_info_registration/queries/validation.sql`
の CASE 式を**同一の評価順**で再現し、投入前に

    - `customer_info_production` に入る行数 (= ArchiveSuccess の rowsRead)
    - `customer_info_error` に入る行数と理由の内訳 (= ArchiveError の rowsRead)

を算出する。実機投入後は ADF の `rowsRead` と突き合わせて判定する
(手順: test/01-storage-csv.md)。

評価順 (validation.sql と一致させること。変更時は両方を同時に直す):
    必須 -> 桁数 -> 文字種/形式 -> 実在日 -> (最後に) policy_no 重複

使い方:
    python test/scripts/csv/simulate_validation.py              # test/data/csv/*.csv を一括
    python test/scripts/csv/simulate_validation.py test/data/csv/scenario_charset.csv
"""

from __future__ import annotations

import argparse
import csv
import datetime
import glob
import os
import re
from collections import Counter

# validation.sql の正規表現と 1:1 で対応させる
RE_HALF_BLANK = re.compile(r"^ *$")  # policy_no / birth_ymd / cellular_phone_no の空白のみ判定
RE_FULL_BLANK = re.compile(r"^　*$")  # name_kana の空白のみ判定 (全角スペース)
RE_POLICY = re.compile(r"^[0-9A-Za-z]+$")
RE_NAME = re.compile(r"^[ァ-ヾ]+　[ァ-ヾ]+$")  # 姓＜全角スペース＞名
RE_BIRTH = re.compile(r"^[0-9]{8}$")
RE_PHONE = re.compile(r"^[0-9]{3}-[0-9]{4}-[0-9]{4}$")

# CSV ヘッダ (ADF がこのヘッダ名で landing の列へマッピングする)
HEADER: tuple[str, ...] = ("顧客_番号", "顧客_氏名", "顧客_生年月日", "顧客_電話番号")

DUPLICATED = "policy_no duplicated"


def format_error(policy_no: str, name_kana: str, birth_ymd: str, cellular_phone_no: str) -> str | None:
    """validation.sql の CASE 式 (format_error) を再現する。問題なければ None。"""
    # 必須 (NULL / 空 / 空白のみ)
    if policy_no is None or RE_HALF_BLANK.match(policy_no):
        return "policy_no required"
    if name_kana is None or RE_FULL_BLANK.match(name_kana):
        return "name_kana required"
    if birth_ymd is None or RE_HALF_BLANK.match(birth_ymd):
        return "birth_ymd required"
    if cellular_phone_no is None or RE_HALF_BLANK.match(cellular_phone_no):
        return "cellular_phone_no required"
    # 桁数
    if len(policy_no) > 10:
        return "policy_no too long (max 10)"
    if len(name_kana) > 50:
        return "name_kana too long (max 50)"
    if len(birth_ymd) != 8:
        return "birth_ymd must be 8 digits"
    if len(cellular_phone_no) > 15:
        return "cellular_phone_no too long (max 15)"
    # 文字種 / 形式
    if not RE_POLICY.match(policy_no):
        return "policy_no must be half-width alphanumeric"
    if not RE_NAME.match(name_kana):
        return "name_kana must be zenkaku katakana in sei<full-width space>mei form"
    if not RE_BIRTH.match(birth_ymd):
        return "birth_ymd must be 8-digit YYYYMMDD"
    if not RE_PHONE.match(cellular_phone_no):
        return "cellular_phone_no must be XXX-XXXX-XXXX"
    # 実在日 (8 桁数字が確定した後)
    year, month, day = int(birth_ymd[:4]), int(birth_ymd[4:6]), int(birth_ymd[6:8])
    if not (1 <= month <= 12 and 1 <= day <= 31):  # SQL のレンジガードに対応
        return "birth_ymd is not a valid calendar date"
    try:
        datetime.date(year, month, day)  # SQL の月別最大日数 + 閏年判定に対応
    except ValueError:
        return "birth_ymd is not a valid calendar date"
    return None


def simulate(path: str) -> tuple[int, int, int, Counter]:
    """CSV 1 ファイルの (入力行数, production 行数, error 行数, 理由内訳) を返す。"""
    with open(path, encoding="cp932", newline="") as fp:
        rows = list(csv.reader(fp))[1:]  # ヘッダ行を除く

    # 列落ちした行は landing で NULL 相当になるため空文字で埋める
    normalized = [(row + ["", "", "", ""])[:4] for row in rows]

    id_count = Counter(row[0] for row in normalized)
    production = 0
    reasons: Counter = Counter()
    for policy_no, name_kana, birth_ymd, cellular_phone_no in normalized:
        error = format_error(policy_no, name_kana, birth_ymd, cellular_phone_no)
        if error is None and id_count[policy_no] == 1:
            production += 1
        else:
            reasons[error or DUPLICATED] += 1

    return len(normalized), production, sum(reasons.values()), reasons


def _parse_args() -> list[str]:
    """対象 CSV のパス一覧を返す (未指定なら test/data/csv 配下をすべて)。"""
    parser = argparse.ArgumentParser(description="validation.sql の判定を再現して期待値を算出する")
    parser.add_argument("paths", nargs="*", help="対象 CSV (未指定なら test/data/csv/*.csv)")
    args = parser.parse_args()
    if args.paths:
        return args.paths
    return sorted(p for p in glob.glob("test/data/csv/*.csv") if not os.path.basename(p).startswith("_"))


def main() -> None:
    """エントリポイント。ファイルごとに期待値を表示する。"""
    for path in _parse_args():
        if not os.path.exists(path):
            print(f"skip (not found): {path}")
            continue
        try:
            total, production, error, reasons = simulate(path)
        except UnicodeDecodeError:
            # Shift_JIS で読めない = 想定外エンコーディング (UTF-8 で作った異常系ファイル等)
            print(f"\n### {os.path.basename(path)}  (cp932 でデコード不可 = 投入すると文字化けする)")
            continue
        print(f"\n### {os.path.basename(path)}  (input={total}, production={production}, error={error})")
        for reason, count in reasons.most_common():
            print(f"    error={count}  {reason}")


if __name__ == "__main__":
    main()
