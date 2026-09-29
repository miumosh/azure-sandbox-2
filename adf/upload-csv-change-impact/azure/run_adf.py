#!/usr/bin/env python3
"""デプロイした ADF に ../inputs/*.csv を 1 ファイルずつ流し、結果をローカル模擬 (../out/summary.json) と比較する。

各入力ファイルについて:
  1. upload コンテナの input/<name>.csv にアップロード
  2. pl_csv_ingest を triggeredFileName=<name>.csv で実行し、完了まで待つ
  3. Succeeded なら archive/success, archive/error の CSV を out-azure/<dataset>__<name>/ にダウンロード
     Failed なら各 activity のエラーを failed.txt に保存
  4. ローカル模擬の同じケースと、状態・success 行・error 行を比較する

使い方: ./run_adf.py [入力 CSV ...]   (省略時は ../inputs/*.csv すべて)
前提: az login 済み、terraform apply と setup-db.sh 実行済み。
"""
import csv
import io
import json
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
API = "api-version=2018-06-01"
POLL_SEC = 15
TIMEOUT_SEC = 30 * 60


def az(*args: str) -> str:
    r = subprocess.run(["az", *args, "--only-show-errors"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"az {' '.join(args[:3])} failed:\n{r.stderr}")
    return r.stdout


def az_rest(method: str, path: str, body: dict | None = None) -> dict:
    args = ["rest", "--method", method, "--url", f"https://management.azure.com{path}"]
    if body is not None:
        args += ["--body", json.dumps(body)]
    out = az(*args)
    return json.loads(out) if out.strip() else {}


def tf_outputs() -> dict:
    r = subprocess.run(["terraform", f"-chdir={HERE}", "output", "-json"], capture_output=True, text=True, check=True)
    return {k: v["value"] for k, v in json.loads(r.stdout).items()}


def blob_args(o: dict, container: str) -> list[str]:
    return ["--auth-mode", "login", "--account-name", o["storage_account_name"], "--container-name", container]


def run_pipeline(o: dict, file_name: str) -> tuple[dict, list[dict]]:
    started = datetime.now(timezone.utc) - timedelta(minutes=1)
    base = f"{o['data_factory_id']}"
    run_id = az_rest("post", f"{base}/pipelines/{o['pipeline_name']}/createRun?{API}",
                     {"triggeredFileName": file_name})["runId"]
    print(f"  runId={run_id}", flush=True)

    deadline = time.time() + TIMEOUT_SEC
    while True:
        run = az_rest("get", f"{base}/pipelineruns/{run_id}?{API}")
        if run["status"] in ("Succeeded", "Failed", "Cancelled"):
            break
        if time.time() > deadline:
            sys.exit(f"timeout waiting for run {run_id} (status={run['status']})")
        time.sleep(POLL_SEC)

    acts = az_rest("post", f"{base}/pipelineruns/{run_id}/queryActivityruns?{API}", {
        "lastUpdatedAfter": started.isoformat(),
        "lastUpdatedBefore": (datetime.now(timezone.utc) + timedelta(minutes=5)).isoformat(),
    }).get("value", [])
    return run, sorted(acts, key=lambda a: a.get("activityRunStart") or "")


def download_latest(o: dict, prefix: str, dest: Path) -> list[list[str]]:
    """archive/<kind>/<stem>_<kind>_<yyyyMMdd_HHmmss>.csv のうち最新を取得し、データ行を返す。"""
    names = json.loads(az("storage", "blob", "list", *blob_args(o, o["archive_container"]),
                          "--prefix", prefix, "--query", "[].name", "-o", "json"))
    if not names:
        return []
    az("storage", "blob", "download", *blob_args(o, o["archive_container"]),
       "--name", sorted(names)[-1], "--file", str(dest), "--overwrite")
    # ADF の "UTF-8" 書き込みは BOM が付く場合があるため utf-8-sig で読む
    return list(csv.reader(io.StringIO(dest.read_text(encoding="utf-8-sig"))))[1:]


def main() -> None:
    o = tf_outputs()
    ds = o["src_csv_dataset"]
    inputs = [Path(p) for p in sys.argv[1:]] or sorted((ROOT / "inputs").glob("*.csv"))
    local_path = ROOT / "out" / "summary.json"
    local = json.loads(local_path.read_text(encoding="utf-8")) if local_path.exists() else {}

    results = {}
    for path in inputs:
        case = f"{ds}__{path.stem}"
        out_dir = HERE / "out-azure" / case
        out_dir.mkdir(parents=True, exist_ok=True)
        for f in out_dir.glob("*"):
            f.unlink()
        print(f"[{case}] upload input/{path.name} -> run", flush=True)

        az("storage", "blob", "upload", *blob_args(o, o["upload_container"]),
           "--name", f"input/{path.name}", "--file", str(path), "--overwrite")
        run, acts = run_pipeline(o, path.name)
        (out_dir / "activity_runs.json").write_text(json.dumps(acts, ensure_ascii=False, indent=2), encoding="utf-8")

        res = {"status": run["status"],
               "activities": {a["activityName"]: a["status"] for a in acts}}
        if run["status"] == "Succeeded":
            res["success"] = download_latest(o, f"archive/success/{path.stem}_success_", out_dir / "success.csv")
            res["error"] = download_latest(o, f"archive/error/{path.stem}_error_", out_dir / "error.csv")
        else:
            errors = [f"{a['activityName']}: {a.get('error', {}).get('message', '')}"
                      for a in acts if a["status"] == "Failed"]
            res["detail"] = "\n".join(errors) or run.get("message", "")
            (out_dir / "failed.txt").write_text(res["detail"] + "\n", encoding="utf-8")
        results[case] = res

    (HERE / "out-azure" / f"summary.{ds}.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n{'case':<30} {'ADF':<10} success error  local(模擬)     compare")
    all_match = True
    for case, r in results.items():
        ok = r["status"] == "Succeeded"
        counts = f"{len(r['success']):>7} {len(r['error']):>5}" if ok else f"{'-':>7} {'-':>5}"
        loc = local.get(case)
        if loc is None:
            verdict, loc_s = "(no local)", "-"
        else:
            loc_s = loc["status"]
            if ok and loc["status"] == "OK":
                same = (sorted(r["success"]) == sorted(loc["success"])
                        and sorted(r["error"]) == sorted(loc["error"]))
            else:
                same = (not ok) and loc["status"] == "COPY_FAILED" and r["activities"].get("InputCSV") == "Failed"
            verdict = "MATCH" if same else "DIFF"
            all_match &= same
        print(f"{case:<30} {r['status']:<10} {counts}  {loc_s:<15} {verdict}")
        if not ok:
            print(f"    {r['detail'][:300]!r}")
    sys.exit(0 if all_match else 1)


if __name__ == "__main__":
    main()
