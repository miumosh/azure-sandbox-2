"""手動テスト (経路1: Storage への CSV 投入) 用のシナリオ CSV を決定的に生成するスクリプト。

`generate_sample_csv.py` (正常系 10 万件) / `generate_invalid_csv.py` (違反種別ごとの量産) を
補完し、**1 ファイル = 1 観点**で少行数・固定値のシナリオ CSV を出力する。乱数を使わないため
毎回まったく同じ内容になり、期待値をドキュメントに固定できる。

出力ファイル (すべて Shift_JIS / LF / ヘッダ有り。例外は末尾の 4 本):

    scenario_known_person.csv     : 経路2 (Function API) が検索する既知データ。全行 valid
    scenario_boundary_ok.csv      : 境界値だが合格する行のみ (10桁 policy_no / 50文字氏名 / 閏日 等)
    scenario_blank_only.csv       : 空白のみ (半角/全角) -> '... required'
    scenario_length.csv           : 桁数超過 -> '... too long' / 'birth_ymd must be 8 digits'
    scenario_charset.csv          : 文字種・形式違反 -> 'must be ...'
    scenario_calendar.csv         : 実在しない日付 -> 'birth_ymd is not a valid calendar date'
    scenario_duplicate.csv        : policy_no 重複 -> 'policy_no duplicated' (重複行は全て NG)
    scenario_header_only.csv      : データ 0 行 -> production が全削除される (同期仕様の確認)
    scenario_loadfail_over255.csv : 255 文字超 -> InputCSV が 22001 で Failed (唯一の pipeline 失敗系)
    scenario_utf8_encoding.csv    : **UTF-8** で出力 (規定は Shift_JIS)。文字化け時の挙動確認
    scenario_crlf.csv             : **CRLF** で出力 (規定は LF)
    scenario_bad_header.csv       : ヘッダ名が規定と違う (ADF のヘッダ名マッピング不一致)

期待値は同階層の `simulate_validation.py` で算出できる (本スクリプトも最後に呼び出して表示する)。
末尾 4 本はロード層 (Copy) の挙動確認用で、検証 SQL に到達しない可能性があるためシミュレータの
予測対象外 (実機で確認する)。

使い方:
    python test/scripts/csv/generate_scenario_csv.py --out-dir test/data/csv
"""

from __future__ import annotations

import argparse
import csv
import os
from dataclasses import dataclass

from simulate_validation import HEADER, simulate

# ----------------------------------------------------------------------------
# 経路2 (Function API) と共有する既知データ
# test/scripts/api/generate_api_requests.py の
# KNOWN_* と同じ値を使う。片方を変えたら両方を直すこと。
# ----------------------------------------------------------------------------
MULTI_NAME, MULTI_BIRTH, MULTI_PHONE = "タナカ　タロウ", "19900101", "090-1111-2222"
SINGLE_NAME, SINGLE_BIRTH, SINGLE_PHONE = "スズキ　ハナコ", "19851215", "080-3333-4444"
OTHER_NAME, OTHER_BIRTH, OTHER_PHONE = "サトウ　イチロウ", "19701010", "070-5555-6666"

# 境界値 (合格側): policy_no 10 文字 (半角英数) / name_kana ちょうど 50 文字 / 閏日
BOUNDARY_POLICY = "AB12345678"
NAME_50 = "ア" * 24 + "　" + "イ" * 25  # 24 + 1 + 25 = 50 文字
NAME_51 = "ア" * 25 + "　" + "イ" * 25  # 51 文字 -> 'name_kana too long (max 50)'
BOUNDARY_BIRTH = "20240229"  # 閏年 2/29 は合格


@dataclass(frozen=True)
class Scenario:
    """1 ファイル分のシナリオ定義。"""

    file_name: str
    purpose: str
    rows: list[list[str]]
    encoding: str = "shift_jis"
    line_terminator: str = "\n"
    header: tuple[str, ...] = HEADER
    simulate_ok: bool = True  # False = ロード層の確認用でシミュレータ対象外


def _valid(policy_no: str) -> list[str]:
    """既定の正常行 (policy_no だけ差し替える)。"""
    return [policy_no, OTHER_NAME, OTHER_BIRTH, OTHER_PHONE]


def _scenarios() -> list[Scenario]:
    """全シナリオの定義を返す。"""
    return [
        # ------------------------------------------------------------------
        # 正常系: 経路2 の検索対象になる既知データ (production に 6 行入る)
        # ------------------------------------------------------------------
        Scenario(
            "scenario_known_person.csv",
            "経路2 の検索キー元データ (同一人物 3 件 / 一意 2 件 / 境界値 1 件)",
            [
                ["0000000001", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],   # 同一人物 (複数 policy_no)
                ["0000000002", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],
                ["0000000003", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],
                ["0000000004", SINGLE_NAME, SINGLE_BIRTH, SINGLE_PHONE],  # 1 件だけヒット
                ["0000000005", OTHER_NAME, OTHER_BIRTH, OTHER_PHONE],
                [BOUNDARY_POLICY, NAME_50, BOUNDARY_BIRTH, "090-0000-0001"],  # 境界値人物
            ],
        ),
        # ------------------------------------------------------------------
        # 正常系: 境界値だけを集めた「全行合格」ファイル
        # ------------------------------------------------------------------
        Scenario(
            "scenario_boundary_ok.csv",
            "境界値だが全行合格 (桁数上限・下限 / 閏日 / 月末)",
            [
                ["1", "ア　イ", "19500101", "000-0000-0000"],            # 最小: policy_no 1 文字 / 氏名 各 1 文字
                ["0123456789", NAME_50, "20240229", "999-9999-9999"],    # 上限: 10 文字 / 50 文字 / 閏日
                [BOUNDARY_POLICY, "ヴァヶ　ヲンヾ", "20000229", "090-0000-0002"],  # 半角英数 mix / 400 年閏
                ["Zz09", "アー　イヽ", "20260430", "090-0000-0003"],       # [ァ-ヾ] 内の長音・繰返し記号 / 4 月末日
                ["9999999999", "アア　イイ", "20261231", "090-0000-0004"],  # 12/31
            ],
        ),
        # ------------------------------------------------------------------
        # 異常系: 必須 (空文字 / 空白のみ)
        # ------------------------------------------------------------------
        Scenario(
            "scenario_blank_only.csv",
            "空文字・空白のみ -> '... required' (name_kana だけ全角スペースが空扱い)",
            [
                _valid("0000000010"),
                ["", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],              # policy_no 空文字
                [" ", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],             # policy_no 半角スペースのみ
                ["0000000011", "", MULTI_BIRTH, MULTI_PHONE],            # name_kana 空文字
                ["0000000012", "　", MULTI_BIRTH, MULTI_PHONE],          # name_kana 全角スペースのみ
                ["0000000013", MULTI_NAME, "", MULTI_PHONE],             # birth_ymd 空文字
                ["0000000014", MULTI_NAME, "  ", MULTI_PHONE],           # birth_ymd 半角スペースのみ
                ["0000000015", MULTI_NAME, MULTI_BIRTH, ""],             # cellular_phone_no 空文字
                ["0000000016", MULTI_NAME, MULTI_BIRTH, " "],            # cellular_phone_no 半角スペースのみ
            ],
        ),
        # ------------------------------------------------------------------
        # 異常系: 桁数
        # ------------------------------------------------------------------
        Scenario(
            "scenario_length.csv",
            "桁数超過 -> '... too long' / 'birth_ymd must be 8 digits'",
            [
                _valid("0000000020"),
                ["01234567890", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],   # policy_no 11 文字
                ["0000000021", NAME_51, MULTI_BIRTH, MULTI_PHONE],       # name_kana 51 文字
                ["0000000022", MULTI_NAME, "1990010", MULTI_PHONE],      # birth_ymd 7 桁
                ["0000000023", MULTI_NAME, "199001011", MULTI_PHONE],    # birth_ymd 9 桁
                ["0000000024", MULTI_NAME, MULTI_BIRTH, "090-1111-22223333"],  # 電話 17 文字
            ],
        ),
        # ------------------------------------------------------------------
        # 異常系: 文字種 / 形式
        # ------------------------------------------------------------------
        Scenario(
            "scenario_charset.csv",
            "文字種・形式違反 -> 'must be ...'",
            [
                _valid("0000000030"),
                ["０１２３４５", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],    # policy_no 全角数字
                ["ABC-12345", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],     # policy_no に記号
                ["0000000031", "たなか　たろう", MULTI_BIRTH, MULTI_PHONE],  # 氏名ひらがな
                ["0000000032", "田中　太郎", MULTI_BIRTH, MULTI_PHONE],    # 氏名漢字
                ["0000000033", "ﾀﾅｶ　ﾀﾛｳ", MULTI_BIRTH, MULTI_PHONE],     # 氏名半角カナ
                ["0000000034", "タナカタロウ", MULTI_BIRTH, MULTI_PHONE],   # 姓名の区切り無し
                ["0000000035", "タナカ タロウ", MULTI_BIRTH, MULTI_PHONE],  # 区切りが半角スペース
                ["0000000036", MULTI_NAME, "1990/1/1", MULTI_PHONE],     # 生年月日 8 文字だが非数字
                ["0000000037", MULTI_NAME, MULTI_BIRTH, "09011112222"],  # 電話ハイフン無し
                ["0000000038", MULTI_NAME, MULTI_BIRTH, "090-1111-222"], # 電話 3-4-3
                ["0000000039", MULTI_NAME, MULTI_BIRTH, "03-1111-2222"], # 電話 2-4-4 (SQL は 3-4-4 固定)
                ["0000000040", MULTI_NAME, MULTI_BIRTH, "０９０ー１１１１ー２２２２"],  # 電話 全角 (区切りは長音記号)
                ["0000000041", MULTI_NAME, MULTI_BIRTH, "0900-1111-2222"],  # 15 文字だが 4-4-4
            ],
        ),
        # ------------------------------------------------------------------
        # 異常系: 実在日
        # ------------------------------------------------------------------
        Scenario(
            "scenario_calendar.csv",
            "実在しない日付 -> 'birth_ymd is not a valid calendar date' (閏日・月末は合格)",
            [
                ["0000000050", MULTI_NAME, "20240229", MULTI_PHONE],     # 合格: 閏年 2/29
                ["0000000051", MULTI_NAME, "20000229", MULTI_PHONE],     # 合格: 400 年閏
                ["0000000052", MULTI_NAME, "20260430", MULTI_PHONE],     # 合格: 4 月末日
                ["0000000053", MULTI_NAME, "20260230", MULTI_PHONE],     # NG: 2/30
                ["0000000054", MULTI_NAME, "20260431", MULTI_PHONE],     # NG: 4/31
                ["0000000055", MULTI_NAME, "20260631", MULTI_PHONE],     # NG: 6/31
                ["0000000056", MULTI_NAME, "20261301", MULTI_PHONE],     # NG: 13 月
                ["0000000057", MULTI_NAME, "20260001", MULTI_PHONE],     # NG: 0 月
                ["0000000058", MULTI_NAME, "20260100", MULTI_PHONE],     # NG: 0 日
                ["0000000059", MULTI_NAME, "19000229", MULTI_PHONE],     # NG: 100 年非閏
            ],
        ),
        # ------------------------------------------------------------------
        # 異常系: policy_no 重複 (reject-all)
        # ------------------------------------------------------------------
        Scenario(
            "scenario_duplicate.csv",
            "policy_no 重複 -> 重複した policy_no を持つ行は**全て** error",
            [
                _valid("0000000060"),
                ["0000000061", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],    # 3 行が同一 policy_no
                ["0000000061", SINGLE_NAME, SINGLE_BIRTH, SINGLE_PHONE],
                ["0000000061", OTHER_NAME, OTHER_BIRTH, OTHER_PHONE],
                ["0000000062", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],    # 2 行が同一 policy_no
                ["0000000062", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],
                ["", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],              # 空 policy_no の重複は
                ["", SINGLE_NAME, SINGLE_BIRTH, SINGLE_PHONE],           # 'required' が優先される
            ],
        ),
        # ------------------------------------------------------------------
        # 異常系: データ 0 行 (production 同期の DELETE を確認する)
        # ------------------------------------------------------------------
        Scenario(
            "scenario_header_only.csv",
            "ヘッダのみ (データ 0 行) -> staging が空 = production 全削除",
            [],
        ),
        # ------------------------------------------------------------------
        # ロード層 (Copy) の確認用。検証 SQL に到達しない可能性があるため実機確認
        # ------------------------------------------------------------------
        Scenario(
            "scenario_loadfail_over255.csv",
            "landing の VARCHAR(255) を超える値 -> InputCSV が 22001 で Failed",
            [
                _valid("0000000070"),
                ["0000000071", "ア" * 256, MULTI_BIRTH, MULTI_PHONE],
            ],
            simulate_ok=False,
        ),
        Scenario(
            "scenario_utf8_encoding.csv",
            "規定 (Shift_JIS) と異なる UTF-8 で投入したときの挙動",
            [
                ["0000000080", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],
                ["0000000081", SINGLE_NAME, SINGLE_BIRTH, SINGLE_PHONE],
            ],
            encoding="utf-8",
            simulate_ok=False,
        ),
        Scenario(
            "scenario_crlf.csv",
            "規定 (LF) と異なる CRLF 改行で投入したときの挙動",
            [
                ["0000000090", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],
                ["0000000091", SINGLE_NAME, SINGLE_BIRTH, SINGLE_PHONE],
            ],
            line_terminator="\r\n",
            simulate_ok=False,
        ),
        Scenario(
            "scenario_bad_header.csv",
            "ヘッダ名が規定と異なる (ADF のヘッダ名マッピングが一致しない)",
            [
                ["0000000100", MULTI_NAME, MULTI_BIRTH, MULTI_PHONE],
                ["0000000101", SINGLE_NAME, SINGLE_BIRTH, SINGLE_PHONE],
            ],
            header=("id", "name", "birth_date", "phone_number"),
            simulate_ok=False,
        ),
    ]


def _write(scenario: Scenario, out_dir: str) -> str:
    """シナリオ 1 件を CSV へ書き出し、パスを返す。"""
    path = os.path.join(out_dir, scenario.file_name)
    with open(path, "w", encoding=scenario.encoding, newline="") as fp:
        writer = csv.writer(fp, lineterminator=scenario.line_terminator)
        writer.writerow(scenario.header)
        writer.writerows(scenario.rows)
    return path


def _parse_args() -> str:
    """出力ディレクトリを返す。"""
    parser = argparse.ArgumentParser(description="手動テスト用のシナリオ CSV を生成する")
    parser.add_argument("--out-dir", type=str, default="test/data/csv", help="出力ディレクトリ")
    return parser.parse_args().out_dir


def main() -> None:
    """エントリポイント。生成後に期待値 (production / error 内訳) を表示する。"""
    out_dir = _parse_args()
    os.makedirs(out_dir, exist_ok=True)

    for scenario in _scenarios():
        path = _write(scenario, out_dir)
        print(f"\n### {scenario.file_name}  — {scenario.purpose}")
        if not scenario.simulate_ok:
            print("    (ロード層の確認用。検証 SQL に到達しない可能性があるため実機で確認する)")
            continue
        total, production, error, reasons = simulate(path)
        print(f"    input={total}, production={production}, error={error}")
        for reason, count in reasons.most_common():
            print(f"      error={count}  {reason}")


if __name__ == "__main__":
    main()
