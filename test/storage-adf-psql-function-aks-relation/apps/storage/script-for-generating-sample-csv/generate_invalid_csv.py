"""バリデーション失敗ケース検証用の「フォーマット違反」CSV を生成するスクリプト。

generate_sample_csv.py と同じファイル仕様 (Shift_JIS / LF / ヘッダ有り) で、
**違反の意図がファイル名で分かる**よう、種別ごとに別ファイルを出力する:

    valid.csv は生成しない (正常系は generate_sample_csv.py)。
    invalid_id_empty.csv          : id が空欄         (必須違反)
    invalid_name_hiragana.csv     : 氏名がひらがな   (型違反)
    invalid_birthdate_7digit.csv  : 生年月日が 7 桁   (桁数違反)
    invalid_phone_nodash.csv      : 電話がハイフン無し (型違反)
    invalid_id_overlength.csv     : id が 11 文字     (桁数違反)
    invalid_id_duplicate.csv      : 同一 id が複数行  (重複違反)
    invalid_mixed.csv             : 上記をすべて混在

各ファイルは「正常 (--valid 行)」+「違反 (--per-category 行)」を混ぜて出力する。
アップロード時の規定名 input/ciupload39.csv への配置は upload-csv-to-blob.sh が行う
(どの版がどのファイルかは manifest に記録される)。

ヘッダ (顧客_番号, 顧客_氏名, 顧客_生年月日, 顧客_電話番号) -> データ項目
(policy_no, name_kana, birth_ymd, cellular_phone_no) のマッピングで ADF が取り込む。

重要: customer_info_landing は **VARCHAR(255)**(寛大上限)なので、桁数超過値もロードに成功し
(22001 でハード Fail しない)、検証 SQL の桁数チェックで customer_info_error へ振り分けられる。
よって**すべての違反種別で pipeline は Succeeded**となり、違反行は理由付きで error_table に入る。

バリデーション規則 (SQL) と違反方針:
    必須   policy_no/name_kana/birth_ymd/cellular_phone_no 非空 -> 空文字  ('policy_no required' 等)
    桁数   policy_no<=10, name_kana<=100, birth_ymd=8, cellular_phone_no<=15 -> 11文字/7桁  ('policy_no too long (max 10)' 等)
    型     name_kana=全角カナ / birth_ymd=数字8桁 / cellular_phone_no=XXX-XXXX-XXXX -> ひらがな/ハイフン無し
    重複   landing 内で policy_no 一意 -> 同一 policy_no 複数行          ('policy_no duplicated')

使い方:
    python generate_invalid_csv.py --valid 5 --per-category 2 --out-dir ./csv
"""

from __future__ import annotations

import argparse
import csv
import os
import random
from dataclasses import dataclass
from datetime import date, timedelta

# 全角カタカナ (正常な氏名生成に使用する文字集合)
KATAKANA: str = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン"

# ひらがな (name 違反行に使用 = カタカナ規則に一致しない)
HIRAGANA: str = "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん"

# CSV ヘッダ (ADF はこのヘッダ名でデータ項目へマッピングする)
HEADER: tuple[str, ...] = ("顧客_番号", "顧客_氏名", "顧客_生年月日", "顧客_電話番号")


@dataclass(frozen=True)
class GeneratorConfig:
    """違反 CSV 生成のパラメータ。"""

    valid: int
    per_category: int
    out_dir: str
    seed: int


# ----------------------------------------------------------------------------
# フィールド生成ヘルパー
# ----------------------------------------------------------------------------
def _id(index: int) -> str:
    """連番ベースのゼロ埋め ID (10 桁 = 正常)。"""
    return f"{index:010d}"


def _name_katakana(rng: random.Random) -> str:
    """全角カタカナの「姓＜全角スペース＞名」(正常)。

    検証規則 ^[ァ-ヾ]+　[ァ-ヾ]+$ (姓＜U+3000＞名) に準拠。各パート 2〜5 文字 (区切り込み最大 11 ≤ 50)。
    """
    sei = "".join(rng.choice(KATAKANA) for _ in range(rng.randint(2, 5)))
    mei = "".join(rng.choice(KATAKANA) for _ in range(rng.randint(2, 5)))
    return f"{sei}　{mei}"


def _name_hiragana(rng: random.Random) -> str:
    """ひらがな 3〜8 文字 (name 規則違反)。"""
    return "".join(rng.choice(HIRAGANA) for _ in range(rng.randint(3, 8)))


def _birth_date(rng: random.Random) -> str:
    """1950-01-01〜2005-12-31 の生年月日を YYYYMMDD で返す (正常)。"""
    start, end = date(1950, 1, 1), date(2005, 12, 31)
    birth = start + timedelta(days=rng.randint(0, (end - start).days))
    return birth.strftime("%Y%m%d")


def _phone(rng: random.Random) -> str:
    """XXX-XXXX-XXXX 形式 (正常)。"""
    return f"{rng.randint(0, 999):03d}-{rng.randint(0, 9999):04d}-{rng.randint(0, 9999):04d}"


# ----------------------------------------------------------------------------
# 行ビルダー: 対象項目だけを違反させ、他は正常値にする
# (列順は HEADER に対応: policy_no, name_kana, birth_ymd, cellular_phone_no)
# (SQL の CASE 順 policy_no->name_kana->birth_ymd->cellular_phone_no で想定理由が付く)
# ----------------------------------------------------------------------------
def _valid_row(rng: random.Random, idx: int) -> list[str]:
    return [_id(idx), _name_katakana(rng), _birth_date(rng), _phone(rng)]


def _row_id_empty(rng: random.Random, idx: int) -> list[str]:
    return ["", _name_katakana(rng), _birth_date(rng), _phone(rng)]


def _row_name_hiragana(rng: random.Random, idx: int) -> list[str]:
    return [_id(idx), _name_hiragana(rng), _birth_date(rng), _phone(rng)]


def _row_birth_7digit(rng: random.Random, idx: int) -> list[str]:
    return [_id(idx), _name_katakana(rng), _birth_date(rng)[:7], _phone(rng)]


def _row_phone_nodash(rng: random.Random, idx: int) -> list[str]:
    return [_id(idx), _name_katakana(rng), _birth_date(rng), "09012345678"]


def _row_id_overlength(rng: random.Random, idx: int) -> list[str]:
    # policy_no を 11 文字に。landing は VARCHAR(255) なのでロードは成功し、SQL の桁数チェックで
    # 'policy_no too long (max 10)' として error 行になる (旧構成のような 22001 ハード Fail はしない)。
    return ["9" + _id(idx), _name_katakana(rng), _birth_date(rng), _phone(rng)]


def _row_name_overlength(rng: random.Random, idx: int) -> list[str]:
    # 氏名を 60 文字に -> 'name_kana too long (max 50)' (>50 で error、landing(255) には収まる)
    return [_id(idx), "ア" * 60, _birth_date(rng), _phone(rng)]


def _dup_pair(rng: random.Random, idx: int) -> list[list[str]]:
    # 同一 policy_no を持つ 2 行。reject-all により両行とも 'policy_no duplicated' で error になる。
    fixed = _id(idx)
    return [
        [fixed, _name_katakana(rng), _birth_date(rng), _phone(rng)],
        [fixed, _name_katakana(rng), _birth_date(rng), _phone(rng)],
    ]


# 1 行で完結する違反種別: (key, 説明, ビルダー)。いずれも error 行になり pipeline は Succeeded。
INRANGE: tuple[tuple[str, str, object], ...] = (
    ("id_empty", "policy_no 空欄 -> 'policy_no required'", _row_id_empty),
    ("name_hiragana", "氏名ひらがな -> 'name_kana must be zenkaku katakana'", _row_name_hiragana),
    ("birthdate_7digit", "生年月日7桁 -> 'birth_ymd must be 8 digits'", _row_birth_7digit),
    ("phone_nodash", "電話ハイフン無し -> 'cellular_phone_no must be XXX-XXXX-XXXX'", _row_phone_nodash),
    ("id_overlength", "policy_no 11文字 -> 'policy_no too long (max 10)'", _row_id_overlength),
    ("name_overlength", "氏名60文字 -> 'name_kana too long (max 50)'", _row_name_overlength),
)


def _write_csv(path: str, rows: list[list[str]]) -> None:
    """Shift_JIS / LF / ヘッダ有り で書き出す。"""
    with open(path, "w", encoding="shift_jis", newline="") as fp:
        writer = csv.writer(fp, lineterminator="\n")
        writer.writerow(HEADER)
        writer.writerows(rows)


def generate(config: GeneratorConfig) -> list[tuple[str, str]]:
    """意図ごとの違反 CSV を生成し、[(ファイル名, 期待結果)] を返す。"""
    os.makedirs(config.out_dir, exist_ok=True)
    rng = random.Random(config.seed)
    counter = {"n": 0}

    def next_idx() -> int:
        counter["n"] += 1
        return counter["n"]

    written: list[tuple[str, str]] = []

    def emit(file_name: str, violation_rows: list[list[str]], note: str) -> None:
        rows = [_valid_row(rng, next_idx()) for _ in range(config.valid)]
        rows.extend(violation_rows)
        rng.shuffle(rows)
        _write_csv(os.path.join(config.out_dir, file_name), rows)
        written.append((file_name, note))

    # 1) 単一種別 (1 行違反 -> customer_info_error)
    for key, desc, builder in INRANGE:
        vr = [builder(rng, next_idx()) for _ in range(config.per_category)]
        emit(
            f"invalid_{key}.csv",
            vr,
            f"Succeeded / customer_info_error={config.per_category} ({desc}) / customer_info_production={config.valid}",
        )

    # 2) policy_no 重複 (1 組 2 行。両行とも 'policy_no duplicated' で error)
    dup_rows: list[list[str]] = []
    for _ in range(config.per_category):
        dup_rows.extend(_dup_pair(rng, next_idx()))
    emit(
        "invalid_id_duplicate.csv",
        dup_rows,
        f"Succeeded / customer_info_error={config.per_category * 2} (policy_no duplicated) / customer_info_production={config.valid}",
    )

    # 3) 全種別混在 (単一種別 + id 重複)
    mixed: list[list[str]] = [
        b(rng, next_idx()) for _, _, b in INRANGE for _ in range(config.per_category)
    ]
    for _ in range(config.per_category):
        mixed.extend(_dup_pair(rng, next_idx()))
    emit(
        "invalid_mixed.csv",
        mixed,
        f"Succeeded / customer_info_error={config.per_category * len(INRANGE) + config.per_category * 2} / customer_info_production={config.valid}",
    )

    return written


def _parse_args() -> GeneratorConfig:
    """コマンドライン引数を解釈して GeneratorConfig を返す。"""
    parser = argparse.ArgumentParser(description="フォーマット違反 CSV を種別ごとに生成する")
    parser.add_argument("--valid", type=int, default=5, help="各ファイルに含める正常行数")
    parser.add_argument("--per-category", type=int, default=2, help="違反種別ごとの行数")
    parser.add_argument("--out-dir", type=str, default="./csv", help="出力ディレクトリ")
    parser.add_argument("--seed", type=int, default=39, help="乱数シード")
    args = parser.parse_args()
    return GeneratorConfig(valid=args.valid, per_category=args.per_category, out_dir=args.out_dir, seed=args.seed)


def main() -> None:
    """エントリポイント。"""
    config = _parse_args()
    written = generate(config)
    print(f"generated {len(written)} files in {os.path.abspath(config.out_dir)}:")
    for file_name, note in written:
        print(f"  {file_name:<32} 期待: {note}")


if __name__ == "__main__":
    main()
