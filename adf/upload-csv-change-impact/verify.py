#!/usr/bin/env python3
"""ds_src_csv の encodingName / rowDelimiter 変更の影響をローカル PostgreSQL で検証する。

ケース = Dataset 定義 (before / after) x 入力 CSV (inputs/*.csv)。各ケースで:
  1. [InputCSV 相当]   Dataset 定義どおりに CSV を読み (Python で ADF DelimitedText を模擬)、
                       pipeline.json の translator マッピングで customer_info_landing に INSERT
  2. [ValidateData]    本番の queries/validation.sql をそのまま実行
  3. [Archive* 相当]   customer_info_production / customer_info_error を out/<case>/ に CSV 出力
Copy 段階で失敗するケース (ヘッダ不一致・255 文字超など) は COPY_FAILED として理由を出力する。

ADF の挙動のうち実機で未確認の部分は引数で切り替えられる (README の「模擬の前提」参照):
  --bom keep            : UTF-8 読み込み時に BOM を除去しない (既定は除去)
  --missing-column null : マッピング元の列がヘッダに無い場合に失敗せず NULL で埋める (既定は失敗)
"""
import argparse
import csv
import io
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PIPELINE_DIR = (HERE / "../../test/storage-adf-psql-function-aks-relation/terraform/envs/hub-subscription"
                "/files/adf_pipeline/customer_info_registration").resolve()
CREATE_TABLES_SQL = (HERE / "../../test/storage-adf-psql-function-aks-relation/apps/psql"
                     "/sql-for-setting-up-database/create-tables.sql").resolve()
VALIDATION_SQL = PIPELINE_DIR / "queries" / "validation.sql"
PIPELINE_JSON = PIPELINE_DIR / "pipeline.json"

PSQL = ["docker", "compose", "-f", str(HERE / "docker-compose.yml"), "exec", "-T", "db",
        "psql", "-U", "postgres", "-d", "appdb", "-X", "-q", "-v", "ON_ERROR_STOP=1"]

# ADF の encodingName -> Python codec (ADF の shift_jis は .NET の CP932 = MS932)
CODECS = {"shift_jis": "cp932", "utf-8": "utf-8"}


class CopyFailed(Exception):
    pass


# ---------------------------------------------------------------------------
# InputCSV (Copy activity) の模擬
# ---------------------------------------------------------------------------
def decode(raw: bytes, encoding_name: str, bom: str) -> str:
    codec = CODECS.get(encoding_name.lower())
    if codec is None:
        raise SystemExit(f"unsupported encodingName: {encoding_name}")
    if codec == "utf-8" and bom == "strip" and raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    # .NET の既定デコーダと同様、デコードできないバイトは例外にせず置換文字にする (= 文字化け)
    return raw.decode(codec, errors="replace")


def parse(text: str, ds: dict) -> list[list[str]]:
    """rowDelimiter / columnDelimiter / quoteChar / escapeChar を文字どおりに解釈して行・列に分割する。"""
    row_d, col_d = ds["rowDelimiter"], ds["columnDelimiter"]
    quote, esc = ds.get("quoteChar", '"'), ds.get("escapeChar", "\\")
    rows, row, field, in_quote, i = [], [], [], False, 0
    while i < len(text):
        c = text[i]
        if in_quote:
            if c == esc and esc != quote and i + 1 < len(text):
                field.append(text[i + 1]); i += 2; continue
            if c == quote:
                in_quote = False
            else:
                field.append(c)
            i += 1; continue
        if c == quote:
            in_quote = True; i += 1; continue
        if text.startswith(row_d, i):
            row.append("".join(field)); rows.append(row); row, field = [], []
            i += len(row_d); continue
        if text.startswith(col_d, i):
            row.append("".join(field)); field = []
            i += len(col_d); continue
        field.append(c); i += 1
    if field or row:  # 最終行が行区切りで終わっていない場合
        row.append("".join(field)); rows.append(row)
    return rows


def copy_to_landing_rows(raw: bytes, ds: dict, mappings: list, args) -> list[list]:
    rows = parse(decode(raw, ds["encodingName"], args.bom), ds)
    if not rows:
        raise CopyFailed("empty file")
    header, data = rows[0], rows[1:]
    if not ds.get("firstRowAsHeader", False):
        raise SystemExit("firstRowAsHeader=false is not supported")

    idx = []
    for m in mappings:
        name = m["source"]["name"]
        if name in header:
            idx.append(header.index(name))
        elif args.missing_column == "null":
            idx.append(None)
        else:
            raise CopyFailed(f"source column '{name}' not found in header {header!r}")

    out = []
    for n, r in enumerate(data, start=2):
        if len(r) != len(header):
            raise CopyFailed(f"row {n}: column count {len(r)} != header {len(header)}: {r!r}")
        # nullValue 既定 = 空文字 -> NULL
        out.append([(r[i] if r[i] != "" else None) if i is not None else None for i in idx])
    return out


# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
def psql(sql: str) -> subprocess.CompletedProcess:
    return subprocess.run(PSQL, input=sql.encode("utf-8"), capture_output=True)


def lit(v) -> str:
    return "NULL" if v is None else "'" + v.replace("'", "''") + "'"


def setup_schema() -> None:
    # AAD ロールへの GRANT / OWNER 移譲はローカルに該当ロールが無いので除外する
    ddl = CREATE_TABLES_SQL.read_text(encoding="utf-8").split("-- AAD ロールへの最小権限付与")[0]
    drop = ("DROP TABLE IF EXISTS customer_info_landing, customer_info_staging,"
            " customer_info_production, customer_info_error;\n")
    r = psql(drop + ddl)
    if r.returncode != 0:
        sys.exit(r.stderr.decode())


def dump(table_sql: str) -> str:
    r = psql(f"\\copy ({table_sql}) TO STDOUT WITH (FORMAT csv, HEADER, FORCE_QUOTE *)")
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode())
    return r.stdout.decode("utf-8")


def run_case(ds: dict, raw: bytes, mappings: list, sinks: list, out_dir: Path, args) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    for f in out_dir.glob("*"):
        f.unlink()
    try:
        rows = copy_to_landing_rows(raw, ds, mappings, args)
    except CopyFailed as e:
        (out_dir / "copy_failed.txt").write_text(str(e) + "\n", encoding="utf-8")
        return {"status": "COPY_FAILED", "detail": str(e)}

    cols = ", ".join(sinks)
    sql = ["TRUNCATE TABLE customer_info_production;",  # ケース間の独立性のため (本番には無い)
           "TRUNCATE TABLE customer_info_landing;"]      # preCopyScript
    sql += [f"INSERT INTO customer_info_landing ({cols}) VALUES ({', '.join(map(lit, r))});" for r in rows]
    r = psql("\n".join(sql))
    if r.returncode != 0:
        msg = r.stderr.decode().strip()
        (out_dir / "copy_failed.txt").write_text(msg + "\n", encoding="utf-8")
        return {"status": "COPY_FAILED", "detail": msg}

    r = psql(VALIDATION_SQL.read_text(encoding="utf-8"))
    if r.returncode != 0:
        msg = r.stderr.decode().strip()
        (out_dir / "validate_failed.txt").write_text(msg + "\n", encoding="utf-8")
        return {"status": "VALIDATE_FAILED", "detail": msg}

    success = dump(f"SELECT {cols} FROM customer_info_production ORDER BY policy_no")
    error = dump(f"SELECT {cols}, error_message FROM customer_info_error ORDER BY policy_no NULLS FIRST")
    (out_dir / "success.csv").write_text(success, encoding="utf-8", newline="")
    (out_dir / "error.csv").write_text(error, encoding="utf-8", newline="")
    return {"status": "OK",
            "success": list(csv.reader(io.StringIO(success)))[1:],
            "error": list(csv.reader(io.StringIO(error)))[1:]}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bom", choices=["strip", "keep"], default="strip")
    ap.add_argument("--missing-column", choices=["fail", "null"], default="fail")
    ap.add_argument("--datasets", nargs="*", default=sorted(str(p) for p in (HERE / "datasets").glob("*.json")))
    ap.add_argument("--inputs", nargs="*", default=sorted(str(p) for p in (HERE / "inputs").glob("*.csv")))
    args = ap.parse_args()

    activities = json.loads(PIPELINE_JSON.read_text(encoding="utf-8"))
    mappings = next(a for a in activities if a["name"] == "InputCSV")["typeProperties"]["translator"]["mappings"]
    sinks = [m["sink"]["name"] for m in mappings]

    setup_schema()
    results = {}
    for ds_path in map(Path, args.datasets):
        # ${upload_container} 等の templatefile 変数は location 内にしか無く、解析には不要
        ds = json.loads(ds_path.read_text(encoding="utf-8"))
        ds_name = re.sub(r"^ds_src_csv\.", "", ds_path.stem)
        for in_path in map(Path, args.inputs):
            case = f"{ds_name}__{in_path.stem}"
            res = run_case(ds, in_path.read_bytes(), mappings, sinks, HERE / "out" / case, args)
            res["dataset"] = f"{ds_name} ({ds['encodingName']}, {ds['rowDelimiter']!r})"
            results[case] = res

    print(f"\n[options] bom={args.bom} missing-column={args.missing_column}\n")
    print(f"{'case':<32} {'status':<15} success error  detail")
    for case, r in results.items():
        if r["status"] == "OK":
            bad = [row for row in r["error"] if row[-1]]
            print(f"{case:<32} {r['status']:<15} {len(r['success']):>7} {len(r['error']):>5}  "
                  + "; ".join(f"{row[0]}:{row[-1]}" for row in bad))
        else:
            print(f"{case:<32} {r['status']:<15} {'-':>7} {'-':>5}  {r['detail'][:150]!r}")

    (HERE / "out" / "summary.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")

    # 本命の比較: 変更前設定 x 変更前フォーマット と 変更後設定 x 変更後フォーマット が同じ結果になるか
    base, new = results.get("before__sjis_lf"), results.get("after__utf8bom_crlf")
    if base and new:
        same = (base["status"] == new["status"] == "OK"
                and base["success"] == new["success"] and base["error"] == new["error"])
        print(f"\n[regression] before__sjis_lf == after__utf8bom_crlf : {'PASS' if same else 'FAIL'}")
        sys.exit(0 if same else 1)


if __name__ == "__main__":
    main()
