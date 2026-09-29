#!/usr/bin/env python3
"""fixtures/base.csv (論理内容) から、エンコード x 改行コード の組合せごとの入力 CSV を inputs/ に生成する。

生成したファイルはそのまま実機 ADF (upload コンテナの input/) へアップロードして裏取りにも使える。
"""
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = HERE / "fixtures" / "base.csv"
OUT = HERE / "inputs"

# name: (python codec, BOM バイト列, 改行コード)
VARIANTS = {
    "sjis_lf":      ("cp932", b"",              "\n"),    # 変更前の規定フォーマット
    "sjis_crlf":    ("cp932", b"",              "\r\n"),
    "utf8bom_crlf": ("utf-8", b"\xef\xbb\xbf",  "\r\n"),  # 変更後の規定フォーマット (Excel の「CSV UTF-8」保存と同じ)
    "utf8bom_lf":   ("utf-8", b"\xef\xbb\xbf",  "\n"),
    "utf8_crlf":    ("utf-8", b"",              "\r\n"),  # BOM なし
}


def main() -> None:
    lines = BASE.read_text(encoding="utf-8").splitlines()
    OUT.mkdir(exist_ok=True)
    for name, (codec, bom, eol) in VARIANTS.items():
        data = bom + "".join(line + eol for line in lines).encode(codec)
        (OUT / f"{name}.csv").write_bytes(data)
        print(f"generated inputs/{name}.csv ({len(data)} bytes)")


if __name__ == "__main__":
    main()
