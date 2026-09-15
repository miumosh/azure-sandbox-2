#!/usr/bin/env bash
# ============================================================================
# 閉域経路の検証スクリプト
# ----------------------------------------------------------------------------
# 閉域化した AI サービスは「VNet の中からしか」検証できない。
# 実行端末からの nslookup / curl は公開 DNS の応答しか見えず判定に使えないため、
# VNet 内の Linux VM で `az vm run-command` 越しにコマンドを実行する。
#
# 判定のコツ:
#   nslookup -> 10.60.10.x (PE のプライベート IP) なら Private 経路
#               公開 IP が返る = ゾーン不足 or VNet リンク漏れ
#   HTTP     -> 403 はネットワーク遮断 / 401・404 はネットワークは通ってアプリ層まで到達
#
# 使い方:
#   ./verify.sh              全アカウント
#   ./verify.sh openai       アカウントを絞る (speech / aiservices / openai)
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

FILTER="${1:-}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

terraform output -json > "$WORK/out.json" || {
  echo "terraform output に失敗しました。apply 済みか確認してください。" >&2; exit 1; }

# --- terraform output から「検査対象ホスト名」と「期待するプライベート IP」を作る ----
FILTER="$FILTER" python3 - "$WORK" <<'PY'
import json, os, sys

work = sys.argv[1]
flt = os.environ.get("FILTER", "")
d = json.load(open(f"{work}/out.json"))

rows = []
for key, acc in d["cognitive_accounts"]["value"].items():
    if flt and key != flt:
        continue
    # private_endpoint_records = PE が Private DNS Zone に登録した A レコード。
    # kind = AIServices は 1 PE でも公開サフィックスごとに IP が分かれる点に注意。
    #
    # レコードの FQDN は <name>.privatelink.<suffix> という **内部名**。
    # MS Docs は「クライアントは privatelink 付きの内部 URL を呼んではいけない」と
    # 明記している (TLS 証明書の SAN にも入っていない)。
    # 実際に SDK が引くのは privatelink を抜いた公開名なので、そちらを検査する。
    for fqdn, ip in (acc["private_endpoint_records"] or {}).items():
        rows.append((key, fqdn.replace(".privatelink.", "."), ip))

if not rows:
    print("PE の DNS レコードが空です。ゾーンが PE に紐付いているか確認してください。", file=sys.stderr)
    sys.exit(1)

with open(f"{work}/targets.tsv", "w") as f:
    for r in rows:
        f.write("\t".join(r) + "\n")

meta = {
    "rg": d["resource_group_name"]["value"],
    "vm": d["jumpbox_vm_name"]["value"] or "",
    "mode": d["ai_network_mode"]["value"],
}
json.dump(meta, open(f"{work}/meta.json", "w"))

# VM 内で実行するスクリプト。getent/curl だけで完結させる。
lines = ["set -u", 'echo "--- nslookup (PE のプライベート IP に解決されるか) ---"']
for key, fqdn, ip in rows:
    lines.append(f'R=$(getent hosts "{fqdn}" | awk \'{{print $1}}\' | head -1)')
    lines.append(f'if [ "$R" = "{ip}" ]; then S="OK   private"; '
                 f'elif [ -z "$R" ]; then S="NG   解決できず"; else S="NG   公開IP=$R"; fi')
    lines.append(f'printf "  %-11s %-58s %s\\n" "{key}" "{fqdn}" "$S"')
lines.append('echo')
lines.append('echo "--- HTTPS 疎通 (ルートパス。到達性の粗い確認にすぎない) ---"')
for key, fqdn, ip in rows:
    lines.append(f'C=$(curl -s -o /dev/null -m 15 -w "%{{http_code}}" "https://{fqdn}/" 2>/dev/null)')
    lines.append(f'printf "  %-11s %-58s HTTP %s\\n" "{key}" "{fqdn}" "$C"')


# --- データ面 API (ここが本当の判定) -------------------------------------------
# ルートパス "/" は public 無効でも 200 を返すため遮断の判定に使えない。
# 実際の API を叩いて 403 "Public access is disabled" が出るかどうかで見る。
# 認証は VM のマネージド ID (Entra ID)。キーを run-command に埋めずに済み、
# かつ「閉域 + Entra ID 認証」という推奨構成そのものの確認になる。
dep = d.get("model_deployment_name", {}).get("value")
oai = d["cognitive_accounts"]["value"].get("openai", {}).get("name")
spch = d["cognitive_accounts"]["value"].get("speech", {}).get("name")

if not flt:
    lines += [
        'echo',
        'echo "--- データ面 API (Entra ID 認証 / 403=遮断 200=疎通) ---"',
        'IMDS="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01"',
        'TOK=$(curl -s -H Metadata:true "$IMDS&resource=https%3A%2F%2Fcognitiveservices.azure.com" '
        '| python3 -c \'import json,sys;print(json.load(sys.stdin).get("access_token",""))\' 2>/dev/null)',
        'if [ -z "$TOK" ]; then echo "  (VM のマネージド ID からトークンを取得できませんでした)"; fi',
    ]
    if oai and dep:
        lines += [
            f'C=$(curl -s -o /tmp/dp.txt -m 25 -w "%{{http_code}}" '
            f'"https://{oai}.openai.azure.com/openai/deployments/{dep}/chat/completions?api-version=2024-10-21" '
            f'-H "Authorization: Bearer $TOK" -H "Content-Type: application/json" '
            f"-d '{{\"messages\":[{{\"role\":\"user\",\"content\":\"say OK\"}}],\"max_completion_tokens\":10}}')",
            f'printf "  %-11s %-58s HTTP %s\\n" "openai" "chat/completions ({dep})" "$C"',
        ]
    if spch:
        lines += [
            f'C=$(curl -s -o /dev/null -m 25 -w "%{{http_code}}" '
            f'"https://{spch}.cognitiveservices.azure.com/speechtotext/v3.1/transcriptions" '
            f'-H "Authorization: Bearer $TOK")',
            f'printf "  %-11s %-58s HTTP %s\\n" "speech" "speechtotext/v3.1/transcriptions" "$C"',
        ]

# 実行端末側でも同じデータ面 API を叩けるようにパラメータを書き出す
with open(f"{work}/dataplane.tsv", "w") as f:
    if oai and dep:
        f.write(f"openai\thttps://{oai}.openai.azure.com/openai/deployments/{dep}/chat/completions?api-version=2024-10-21\n")
    if spch:
        f.write(f"speech\thttps://{spch}.cognitiveservices.azure.com/speechtotext/v3.1/transcriptions\n")

open(f"{work}/remote.sh", "w").write("\n".join(lines) + "\n")
PY

RG=$(python3 -c "import json;print(json.load(open('$WORK/meta.json'))['rg'])")
VM=$(python3 -c "import json;print(json.load(open('$WORK/meta.json'))['vm'])")
MODE=$(python3 -c "import json;print(json.load(open('$WORK/meta.json'))['mode'])")

echo "== 検証対象 =================================================="
echo "  Resource Group  : $RG"
echo "  Probe VM        : ${VM:-（なし）}"
echo "  ai_network_mode : $MODE"
echo

if [ -z "$VM" ] || [ "$VM" = "None" ]; then
  echo "enable_jumpbox = true で apply してください (VNet 内からでないと検証できません)" >&2
  exit 1
fi

echo "== VNet 内 (probe VM) からの結果 =============================="
az vm run-command invoke \
  -g "$RG" -n "$VM" \
  --command-id RunShellScript \
  --scripts "@$WORK/remote.sh" \
  --query "value[0].message" -o tsv 2>/dev/null \
  | sed -n '/\[stdout\]/,/\[stderr\]/p' | sed '1d;$d'

echo
echo "== 実行端末 (VNet 外) からの結果 ==============================="
echo "  公開 IP に解決されるのは正常 (公開 DNS は誰からでも引ける)。"
echo "  ルートパス / は public 無効でも 200 を返すため判定に使えない。下のデータ面 API で見る。"
while IFS=$'\t' read -r key fqdn peip; do
  [ -z "${fqdn:-}" ] && continue
  R=$(getent hosts "$fqdn" | awk '{print $1}' | head -1)
  C=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$fqdn/" 2>/dev/null)
  printf '  %-11s %-58s %-16s HTTP %s\n' "$key" "$fqdn" "${R:-解決できず}" "$C"
done < "$WORK/targets.tsv"

echo
echo "  -- データ面 API (VNet 外)。403 \"Public access is disabled\" が閉域化の証拠 --"
TOKEN=$(az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv 2>/dev/null)
while IFS=$'\t' read -r key url; do
  [ -z "${url:-}" ] && continue
  if [ "$key" = "openai" ]; then
    BODY='{"messages":[{"role":"user","content":"say OK"}],"max_completion_tokens":10}'
    C=$(curl -s -o "$WORK/r.txt" -m 20 -w '%{http_code}' "$url" \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$BODY")
  else
    C=$(curl -s -o "$WORK/r.txt" -m 20 -w '%{http_code}' "$url" -H "Authorization: Bearer $TOKEN")
  fi
  MSG=$(python3 -c "
import json,sys
try: print(json.load(open('$WORK/r.txt')).get('error',{}).get('message','')[:60])
except Exception: print('')
" 2>/dev/null)
  printf '  %-11s HTTP %-5s %s\n' "$key" "$C" "$MSG"
done < "$WORK/dataplane.tsv"
