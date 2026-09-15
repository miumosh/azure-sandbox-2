# 異常系テスト（Validation / AKS リクエスト / 複数 policy_no）

ジョブ失敗ではなく「正常に Succeeded するが、入力が**異常系**のときに期待どおり振り分く／応答する」ことを
網羅確認する。対象は次の3系統。

- **A. Validation 異常系** … CSV の各フィールド違反・policy_no 重複が `customer_info_error` に正しい理由で入る
- **B. AKS リクエスト異常系** … 照合 NOT_FOUND / 形式不正 BAD_REQUEST / 必須欠落
- **C. policy_no 複数 MATCH** … 同一人物（氏名・生年月日・電話が一致）が複数 ID を持つとき配列で返る

最終実行・確認日: 2026-06-18。

## 確認手段と制約

成果物 Storage / PostgreSQL は**完全閉域**のため、ローカルからの確認手段は限られる。本書は次の組合せで網羅する。

| 確認対象 | 手段 | 理由 |
| --- | --- | --- |
| error/production **件数** | ADF Copy アクティビティの **`rowsRead`**（`ArchiveSuccess`=production / `ArchiveError`=error / `InputCSV`=landing 全件） | 閉域 DB に触れずに件数が取れる |
| error **理由** (`error_message`) | ① `validation.sql` の**決定的シミュレーション**（下記スクリプト、CASE 式を同一順で再現）<br>② 踏み台 VM の **psql**（ライブ確証が要るとき） | archive CSV はローカルから読めない（RBAC 不足／アカウントキー取得は不可方針） |
| AKS→Function→DB **E2E** | AKS `person-id-app` の**公開 IP**へ `curl`（`POST /api/customers/search`） | LoadBalancer は公開。Function/DB は閉域だが AKS 経由で貫通 |

> 注意: パイプラインは毎回 `customer_info_production` を staging に**同期**（案11: UPSERT＋消失行 DELETE）する。結果は「production＝今回バッチの valid 行」。異常系 CSV を流すと
> production はそのファイルの valid 行数まで縮む。本番相当データに戻すには `valid.csv` を再アップロードする
> （[README](../README.md) 手順7）。

---

## A. Validation 異常系

`apps/storage/script-for-generating-sample-csv/generate_invalid_csv.py --valid 5 --per-category 2` で 8 ファイル生成。
`validation.sql` の CASE 評価順（required→桁数→文字種/形式→実在日、最後に policy_no 重複）で理由が決まる。

> **新ルール（未カテゴリ）**: 以下は現行 8 カテゴリには未収録。下記シミュレータ（更新済み `fmt_error`）で判定でき、
> 環境再構築後に手製 CSV で実機確認する: ①空白のみ（name_kana=全角スペース / 他=半角スペース）→ `… required`
> ②policy_no 全角・記号 → `policy_no must be half-width alphanumeric` ③携帯 3-4-3 や桁違い → `… must be XXX-XXXX-XXXX`
> ④実在しない日付 `20260230` / `20261301`（閏年 `20240229` は合格）→ `birth_ymd is not a valid calendar date`。
> `generate_invalid_csv.py` の `INRANGE` へカテゴリ追加すれば自動生成に組み込める（任意）。

### 期待値とシミュレーション結果（全件一致）

| ファイル | 期待 production | 期待 error（理由） | シミュレーション |
| --- | --- | --- | --- |
| `invalid_id_empty.csv` | 5 | 2 `policy_no required` | ✅ 一致 |
| `invalid_name_hiragana.csv` | 5 | 2 `name_kana must be zenkaku katakana …` | ✅ 一致 |
| `invalid_birthdate_7digit.csv` | 5 | 2 `birth_ymd must be 8 digits` | ✅ 一致 |
| `invalid_phone_nodash.csv` | 5 | 2 `cellular_phone_no must be XXX-XXXX-XXXX` | ✅ 一致 |
| `invalid_id_overlength.csv` | 5 | 2 `policy_no too long (max 10)` | ✅ 一致 |
| `invalid_name_overlength.csv` | 5 | 2 `name_kana too long (max 50)` | ✅ 一致 |
| `invalid_id_duplicate.csv` | 5 | 4 `policy_no duplicated`（重複 policy_no は全行 NG） | ✅ 一致 |
| `invalid_mixed.csv` | 5 | 16（6種×2 + 重複2組×2） | ✅ 一致 |

### ライブ確認（`invalid_mixed.csv` を実投入）

`rowsRead`: `InputCSV=21`（5 valid + 16 違反）/ **`ArchiveError=16`** / **`ArchiveSuccess=5`** → 期待どおり error 振り分けが**実機で**成立。

理由まで**ライブで**確証する場合は、投入後に踏み台 VM から:

```sql
-- 踏み台 VM 上（手順4のパスワードレス接続）
psql "host=ci00-psql.postgres.database.azure.com port=5432 dbname=appdb user=ci00-jumpbox sslmode=require" -c "
  SELECT error_message, count(*) FROM customer_info_error GROUP BY error_message ORDER BY 2 DESC;
  SELECT count(*) AS production FROM customer_info_production;"
```

### 全カテゴリをライブで個別確認したい場合

各ファイルを順に投入（**同時実行は production 入替が競合するので不可**。必ず直列）:

```bash
for f in id_empty name_hiragana birthdate_7digit phone_nodash id_overlength name_overlength id_duplicate mixed; do
  bash apps/storage/script-for-generating-sample-csv/upload-csv-to-blob.sh ./csv/invalid_${f}.csv
  # 完了を待ってから次へ（ADF Monitor もしくは pipeline-run show で Succeeded を確認）
done
```

---

## B. AKS リクエスト異常系

AKS `person-id-app` 公開 IP へ `POST /api/customers/search`（form: `name_kana` / `birth_ymd` / `cellular_phone_no`）。

| # | 入力 | 期待 | 実結果 |
| --- | --- | --- | --- |
| A | 完全に存在しない人 | NOT_FOUND | ✅ `{"result_code":"NOT_FOUND","policy_no":[]}` |
| B | 実在の氏名+生年月日だが**電話だけ違う**（3項目 AND 不一致） | NOT_FOUND | ✅ NOT_FOUND |
| C | 生年月日が 8 桁でない | BAD_REQUEST | ✅ `…(birth_ymd は YYYYMMDD)` |
| D | 電話番号ハイフン無し | BAD_REQUEST | ✅ `…(cellular_phone_no は XXX-XXXX-XXXX)` |
| E | 必須項目欠落（cellular_phone_no 無し） | 400 系 | ⚠️ **FastAPI 422**（`{"detail":[{"type":"missing",…}]}`）。アプリの BAD_REQUEST ではなく FastAPI の `Form(...)` 必須チェックで弾かれる |
| F | name_kana が 50 文字超 | BAD_REQUEST | ✅ `…(name_kana は全角カナ 50 文字以内)` |

```bash
ep="http://<AKS_PUBLIC_IP>/api/customers/search"
curl -s -X POST "$ep" -F "name_kana=ナイ　ヒト" -F "birth_ymd=20201231" -F "cellular_phone_no=000-0000-0000"   # A
curl -s -X POST "$ep" -F "name_kana=チノイ　ソハユ" -F "birth_ymd=1950062" -F "cellular_phone_no=661-4172-5834" # C
```

> **既知の挙動**: Function は `name_kana` の**文字種（カタカナ）を検証しない**（長さ ≤50 のみ）。文字種検証は ADF/SQL 側だけにある。
> そのため非カタカナ名（例 `tanaka`）は BAD_REQUEST にならず **NOT_FOUND** になる（照合で一致しないだけ）。
> 必須欠落（E）は AKS(FastAPI) 層で 422、形式不正（C/D/F）は Function 層で BAD_REQUEST、と**層が異なる**点に注意。

---

## C. policy_no 複数 MATCH

同一人物（`name_kana`/`birth_ymd`/`cellular_phone_no` が同一）で `policy_no` だけ異なる行は、重複判定（partition by policy_no）に
当たらず**全て production に入る**。検索すると `policy_no` が**配列**で返る（`ORDER BY policy_no`）。

テスト CSV（shift_jis で生成。同一人物 3 行 + 一意 2 行）:

```python
import csv
HEADER=("顧客_番号","顧客_氏名","顧客_生年月日","顧客_電話番号")
rows=[
  ["0000000001","タナカ　タロウ","19900101","090-1111-2222"],
  ["0000000002","タナカ　タロウ","19900101","090-1111-2222"],
  ["0000000003","タナカ　タロウ","19900101","090-1111-2222"],
  ["0000000004","スズキ　ハナコ","19851215","080-3333-4444"],
  ["0000000005","サトウ　イチロウ","19701010","070-5555-6666"],
]
with open("./csv/multi_policy.csv","w",encoding="shift_jis",newline="") as f:
    w=csv.writer(f,lineterminator="\n"); w.writerow(HEADER); w.writerows(rows)
```

ライブ確認:
- `rowsRead`: `InputCSV=5` / `ArchiveError=0` / `ArchiveSuccess=5`（5 行すべて production）✅
- E2E（同一人物で検索）→ **`{"result_code":"MATCH","policy_no":["0000000001","0000000002","0000000003"]}`** ✅（3 件・昇順）
- E2E（一意な人で検索）→ `{"result_code":"MATCH","policy_no":["0000000004"]}` ✅（1 件）

---

## 付録: `validation.sql` 決定的シミュレータ

archive を読めない環境でも error 理由を厳密に予測できる（`validation.sql` の CASE 式・評価順を同一に再現）。

```python
import csv, re, datetime
from collections import Counter
RE_HALF_BLANK=re.compile(r'^ *$'); RE_FULL_BLANK=re.compile(r'^　*$')
RE_POLICY=re.compile(r'^[0-9A-Za-z]+$'); RE_NAME=re.compile(r'^[ァ-ヾ]+　[ァ-ヾ]+$')
RE_BIRTH=re.compile(r'^[0-9]{8}$'); RE_PHONE=re.compile(r'^[0-9]{3}-[0-9]{4}-[0-9]{4}$')
def fmt_error(p,n,b,c):
    if p is None or RE_HALF_BLANK.match(p): return 'policy_no required'           # 空 / 半角スペースのみ
    if n is None or RE_FULL_BLANK.match(n): return 'name_kana required'           # 空 / 全角スペースのみ
    if b is None or RE_HALF_BLANK.match(b): return 'birth_ymd required'
    if c is None or RE_HALF_BLANK.match(c): return 'cellular_phone_no required'
    if len(p)>10: return 'policy_no too long (max 10)'
    if len(n)>50: return 'name_kana too long (max 50)'
    if len(b)!=8: return 'birth_ymd must be 8 digits'
    if len(c)>15: return 'cellular_phone_no too long (max 15)'                    # production 列 VARCHAR(15)
    if not RE_POLICY.match(p): return 'policy_no must be half-width alphanumeric'
    if not RE_NAME.match(n):   return 'name_kana must be zenkaku katakana in sei<full-width space>mei form'
    if not RE_BIRTH.match(b):  return 'birth_ymd must be 8-digit YYYYMMDD'
    if not RE_PHONE.match(c):  return 'cellular_phone_no must be XXX-XXXX-XXXX'   # 3-4-4 固定
    y,m,d=int(b[:4]),int(b[4:6]),int(b[6:8])                                      # 実在日 (8桁数字確定後)
    if not (1<=m<=12 and 1<=d<=31):                                               # 月日レンジガード(SQL は to_date 例外回避)
        return 'birth_ymd is not a valid calendar date'
    try: datetime.date(y,m,d)                                                     # SQL の to_date round-trip 相当 (閏年も判定)
    except ValueError: return 'birth_ymd is not a valid calendar date'
    return None
def simulate(path):
    rows=list(csv.reader(open(path,encoding="cp932",newline="")))[1:]
    idc=Counter(r[0] for r in rows); prod=0; reasons=Counter()
    for p,n,b,c in (r[:4] for r in rows):
        fe=fmt_error(p,n,b,c)
        if fe is None and idc[p]==1: prod+=1
        else: reasons[fe or 'policy_no duplicated']+=1
    return prod, sum(reasons.values()), reasons
```

## 関連

- **手動テストの実施手順**（経路別・網羅パターン表・生成スクリプト）: [../test/README.md](../test/README.md)
- ADF 取り込みパイプライン（構成・確認手順）: [pipeline.md](./pipeline.md)
- トラブルシュート（恒常 diff 等）: [troubleshooting.md](./troubleshooting.md)
- ランタイム確認（正常系 E2E）: [../README.md](../README.md) の「動作の流れと確認方法」
