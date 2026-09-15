"""アップロード検証用のサンプル CSV ファイルを生成するスクリプト。

「アップロードされる想定の CSV ファイル」仕様に従ってダミーデータを生成する。

仕様:
    - 出力ファイル名: valid.csv (意図が分かる名前で出力する)
        ※ Storage への配置は**手動**で行う (規定名 input/ciupload39.csv にリネームして
          アップロードする)。本スクリプトは中身の生成のみに専念する。
    - Encoding: Shift_JIS
    - File Format: CSV (ヘッダ有り / フッタなし)
    - Header: 顧客_番号, 顧客_氏名, 顧客_生年月日, 顧客_電話番号
    - Delimiter: ","
    - 改行コード: LF
    - データ件数: 既定 10 万件
    - データ項目 (ヘッダ -> データ項目 のマッピング):
        顧客_番号     -> policy_no         (string, max length 10)
        顧客_氏名     -> name_kana         (string, max length 50, 全角カタカナ)
        顧客_生年月日 -> birth_ymd         (string, max length 8, YYYYMMDD)
        顧客_電話番号 -> cellular_phone_no (string, max length 15, XXX-XXXX-XXXX)

使い方:
    python test/scripts/csv/generate_sample_csv.py --rows 100000 --out-dir test/data/csv
    -> test/data/csv/valid.csv を生成。以降のアップロードは手動 (test/README.md 参照)。
"""

from __future__ import annotations

import argparse
import csv
import os
import random
from dataclasses import dataclass
from datetime import date, timedelta

# 全角カタカナ (氏名生成に使用する文字集合)
KATAKANA: str = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲン"

# CSV ヘッダ (ADF はこのヘッダ名でデータ項目へマッピングする)
HEADER: tuple[str, ...] = ("顧客_番号", "顧客_氏名", "顧客_生年月日", "顧客_電話番号")


@dataclass(frozen=True)
class GeneratorConfig:
    """CSV 生成のパラメータをまとめた設定値。"""

    rows: int
    out_dir: str
    seed: int


def _random_id(index: int) -> str:
    """連番ベースのゼロ埋め ID を返す (最大 10 桁)。"""
    return f"{index:010d}"


def _random_name(rng: random.Random) -> str:
    """全角カタカナの「姓＜全角スペース＞名」を生成する。

    検証規則 ^[ァ-ヾ]+　[ァ-ヾ]+$ (姓＜U+3000＞名) に準拠させるため、姓・名の 2 パートを
    全角スペースで結合する。各パート 2〜5 文字 (合計 + 区切りで最大 11 文字 ≤ 50)。
    """
    sei = "".join(rng.choice(KATAKANA) for _ in range(rng.randint(2, 5)))
    mei = "".join(rng.choice(KATAKANA) for _ in range(rng.randint(2, 5)))
    return f"{sei}　{mei}"


def _random_birth_date(rng: random.Random) -> str:
    """1950-01-01 〜 2005-12-31 の生年月日を YYYYMMDD 形式で返す。"""
    start = date(1950, 1, 1)
    end = date(2005, 12, 31)
    offset_days = rng.randint(0, (end - start).days)
    birth = start + timedelta(days=offset_days)
    return birth.strftime("%Y%m%d")


def _random_phone(rng: random.Random) -> str:
    """XXX-XXXX-XXXX 形式の電話番号を生成する。"""
    first = rng.randint(0, 999)
    second = rng.randint(0, 9999)
    third = rng.randint(0, 9999)
    return f"{first:03d}-{second:04d}-{third:04d}"


def _build_row(index: int, rng: random.Random) -> list[str]:
    """CSV の 1 行分 (4 カラム) を生成する。

    並び順はヘッダ (顧客_番号, 顧客_氏名, 顧客_生年月日, 顧客_電話番号) に対応する。
    """
    return [
        _random_id(index),
        _random_name(rng),
        _random_birth_date(rng),
        _random_phone(rng),
    ]


def _output_path(out_dir: str) -> str:
    """意図が分かるファイル名 (valid.csv) のフルパスを返す。"""
    return os.path.join(out_dir, "valid.csv")


def generate(config: GeneratorConfig) -> str:
    """設定に従って CSV を生成し、出力ファイルパスを返す。

    Shift_JIS / LF 改行 / ヘッダ有り で書き出す。

    Args:
        config: 生成パラメータ。

    Returns:
        生成された CSV ファイルの絶対パス。
    """
    os.makedirs(config.out_dir, exist_ok=True)
    rng = random.Random(config.seed)
    path = _output_path(config.out_dir)

    # newline="" + lineterminator="\n" で LF 改行を維持する
    with open(path, "w", encoding="shift_jis", newline="") as fp:
        writer = csv.writer(fp, lineterminator="\n")
        writer.writerow(HEADER)
        for index in range(1, config.rows + 1):
            writer.writerow(_build_row(index, rng))

    return os.path.abspath(path)


def _parse_args() -> GeneratorConfig:
    """コマンドライン引数を解釈して GeneratorConfig を返す。"""
    parser = argparse.ArgumentParser(description="サンプル CSV を生成する")
    parser.add_argument("--rows", type=int, default=100_000, help="生成する行数")
    parser.add_argument("--out-dir", type=str, default="test/data/csv", help="出力ディレクトリ")
    parser.add_argument("--seed", type=int, default=39, help="乱数シード")
    args = parser.parse_args()
    return GeneratorConfig(rows=args.rows, out_dir=args.out_dir, seed=args.seed)


def main() -> None:
    """エントリポイント。"""
    config = _parse_args()
    path = generate(config)
    print(f"generated {config.rows} rows -> {path}")


if __name__ == "__main__":
    main()
