#!/usr/bin/env bash
# 入力 CSV 生成 -> PostgreSQL 起動 -> 全ケース検証。引数は verify.py にそのまま渡す (例: ./run.sh --bom keep)
set -euo pipefail
cd "$(dirname "$0")"
python3 make_inputs.py
docker compose up -d --wait
python3 verify.py "$@"
