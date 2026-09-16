# サブスクリプションで Azure Cache for Redis を作成できるか判定する方法

2026-09-15 に実測。退役が進行しており、**サブスクリプションによっては新規作成が RP 側でブロックされる**。
その可否を事前に知る方法を調べた結果をまとめる。

## 背景: 何が起きるか

作成できないサブスクリプションでは、Terraform / CLI / ポータルのいずれからでも HTTP 400 で弾かれる。

```
Error: creating Redis ... unexpected status 400 (400 Bad Request) with error:
BadRequest: Azure Cache for Redis is retiring, create Azure Managed Redis instance instead.
Learn more: https://aka.ms/AzureCacheForRedisRetirement
```

退役スケジュール:

- **2028/09/30** — Basic / Standard / Premium 全廃止
- **2027/03/31** — Enterprise / Enterprise Flash 廃止
- 既存顧客への新規作成ブロックは **2026/10/01** 開始とアナウンスされていた
  (その後「全クラウドで既存顧客向けの作成ブロックは撤回」という続報あり。要確認)

実測した範囲では、**Azure Cache for Redis を 1 つも持っていないサブスクリプション**は
2026/09/15 時点で既にブロックされていた。「既存顧客かどうか」で判定されている可能性が高い。

## 結論 (先に要点)

**非破壊で確実に判定する方法は無い。** 確実な判定は「正当な作成リクエストを投げてみる」しかない。

実用的には次の 2 段構えになる。

1. `az redis list` で既存インスタンスの有無を見る (完全に安全・ヒューリスティック)
2. 確定させたいなら **Basic C0** (最安 SKU) で作成を試す
   - ブロック済み → 400 で即失敗し、**何も作られない**
   - 未ブロック → **実際に作成が始まる**ので、成功したら即 delete する

## 試した判定方法と結果

すべて「ブロックされていることが確実なサブスクリプション」に対して実測した。

| 方法 | ブロックを検出 | 破壊性 | 実測結果 |
|------|:---:|:---:|----------|
| `az provider show -n Microsoft.Cache` の `registrationState` | ✗ | 無 | `Registered` のまま。無関係 |
| provider の `resourceTypes` に `Redis` があるか | ✗ | 無 | 48 リージョンで正常に存在 |
| `az deployment group validate` (preflight) | ✗ | 無 | `provisioningState: Succeeded` |
| `az deployment group what-if` | ✗ | 無 | `changeType: Create` / `status: Succeeded` |
| `checkNameAvailability` | ✗ | 無 | 名前は利用可能と返る |
| わざと不正な SKU / 名前 / RG で PUT | ✗ | 無 | 退役ゲートより先に各検証で弾かれる (下記) |
| **正当なボディで PUT (Basic C0)** | **✓** | **条件付き** | 退役エラーが返る |
| `az redis list` の件数 | △ | 無 | 0 件 = 新規顧客 = ブロックの可能性大 |

### なぜ preflight で検出できないのか

`validate` / `what-if` は **ARM のテンプレート検証層**までしか見ない。
「退役したのでもう作らせない」は **RP (Microsoft.Cache) のビジネスルール**で、
実際の PUT を受けて初めて評価される。したがって preflight は素通りする。

### 退役ゲートは全検証の「最後」にある

わざと不正なリクエストを投げれば、実作成されずに退役エラーだけ引き出せるのでは、と考えて
検証順序を調べたが、**退役ゲートは最後**だった。

| 投げたもの | 返ってきたエラー |
|------------|------------------|
| SKU 名が不正 (`Bogus`) | `InvalidRequestBody` — sku.name が不正 |
| location が不正 (`nowhere-region`) | `InvalidResourceLocation` |
| キャッシュ名が不正 (`probe_invalid_name`) | `InvalidResourceName` |
| 存在しない RG | `ResourceGroupNotFound` |
| **すべて正当** | **`BadRequest` — Azure Cache for Redis is retiring** |

つまり「安全に失敗させて退役エラーだけ見る」ことはできない。
退役エラーが見えた時点で、それ以外の条件はすべて正当だったということ。

### SKU には依存しない

Premium P1 でも **Basic C0** でも同じ退役エラーが返った。
ティアごとの制限ではなく、**サブスクリプション単位の制限**。
プローブに最安の Basic C0 を使ってよい根拠になる。

## 手順

### 手順 1: 既存インスタンスの確認 (安全・まずこれ)

```bash
# 単一サブスクリプション
az redis list --subscription <SUB_ID> -o table

# アクセス可能な全サブスクリプションを横断
for s in $(az account list --all --query "[?state=='Enabled'].id" -o tsv); do
  n=$(az account list --all --query "[?id=='$s'].name" -o tsv)
  c=$(az redis list --subscription "$s" --query 'length(@)' -o tsv 2>/dev/null || echo "取得不可")
  echo "$n ($s) : ${c} 件"
done
```

1 件以上あれば「既存顧客」として作成できる可能性が高い。0 件ならブロックされている可能性が高い。
あくまでヒューリスティックであり、確証にはならない。

### 手順 2: 実作成プローブ (確定させたい場合)

**最安の Basic C0 を使い、成功したら即削除する。**

```bash
SUB=<SUB_ID>
RG=<既存の RG>
NAME=probe-redis-$RANDOM

az rest --method put \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Cache/redis/$NAME?api-version=2024-11-01" \
  --headers "Content-Type=application/json" \
  --body '{"location":"japaneast","properties":{"sku":{"name":"Basic","family":"C","capacity":0}}}'
```

| 応答 | 意味 | 後始末 |
|------|------|--------|
| `BadRequest: Azure Cache for Redis is retiring` | **作成不可**。リソースは作られていない | 不要 |
| `201 Created` / `200 OK` | **作成可能**。実リソースの作成が始まっている | **即削除が必要** |

```bash
# 作成できてしまった場合
az redis delete --subscription $SUB -g $RG -n $NAME --yes
```

Basic C0 は最安ティアなので、数分で削除すればコストはごくわずか。
ただし **削除を忘れると課金が続く**ので必ず確認すること。

同じことは CLI でもできる (中身は同じ RP 呼び出し)。

```bash
az redis create --subscription $SUB -g $RG -n $NAME \
  --location japaneast --sku Basic --vm-size c0
```

## 作成できなかった場合の選択肢

| 方針 | 内容 | 注意 |
|------|------|------|
| 既存キャッシュを持つサブスクを使う | 「既存顧客」扱いのサブスクリプションなら作成できる可能性がある | 2026/10/01 以降の扱いは要確認 |
| **Azure Managed Redis** に移る | 後継サービス。`azurerm_managed_redis` | **`zones` 属性が無く**、Zone redundant by default。ゾーンを選ぶ概念自体が無い |
| Azure Cache for Redis **Enterprise** | `azurerm_redis_enterprise_cluster` は `zones` を持つ | 2027/03/31 廃止。最小 E10 で Premium P1 より高額 |

ゾーン構成の検証が目的の場合、**Azure Managed Redis では代替にならない**点に注意
(ゾーンをユーザーが指定できないため、「ゾーン変更が replace になるか」という問い自体が成立しない)。

## 実測ログ (2026-09-15 / サブスクリプション `b73908f0-...`)

```
$ az provider show -n Microsoft.Cache --query registrationState
"Registered"                                    # ← ブロックされていても Registered

$ az provider show -n Microsoft.Cache --query "resourceTypes[?resourceType=='Redis'].locations | length(@)"
48                                              # ← 型も正常に存在する

$ az deployment group validate -g redisaz-rg --template-file redis-probe.json
"provisioningState": "Succeeded"                # ← 素通り

$ az deployment group what-if -g redisaz-rg --template-file redis-probe.json
"changeType": "Create", "status": "Succeeded"   # ← 素通り

$ az rest --method put ... --body '{"location":"japaneast","properties":{"sku":{"name":"Basic","family":"C","capacity":0}}}'
ERROR: Bad Request({"error":{"code":"BadRequest","message":
  "Azure Cache for Redis is retiring, create Azure Managed Redis instance instead. ..."}})

$ az resource list -g redisaz-rg -o table
(空)                                             # ← 何も作られていない
```

なお `resourceTypes[?resourceType=='redis']` (小文字) と書くと JMESPath は大文字小文字を
区別するため `[]` が返る。**「型が存在しない = ブロックされている」と誤読しやすいので注意。**
正しくは `Redis` (先頭大文字)。

## 参照

- [Retirement: Azure Cache for Redis is retiring on September 30, 2028](https://www.microsoft.com/releasecommunications/api/v2/azure/rss/499577)
- [Frequently asked questions (FAQ) on the retirement of Azure Cache for Redis](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/retirement-faq)
- [Azure Cache for Redis Retirement: What to Know and How to Prepare](https://techcommunity.microsoft.com/blog/azure-managed-redis/azure-cache-for-redis-retirement-what-to-know-and-how-to-prepare/4458721)
- [What is Azure Managed Redis?](https://learn.microsoft.com/en-us/azure/redis/overview)

---

# 追補: 「組織で過去に作成されたか」を調べる

作成可否は **「その組織で過去に Azure Cache for Redis を作成したことがあるか」** で決まる、という
情報を得たため、その観点での調査方法を追加で実測した (2026-09-15)。

> 注意: Microsoft が実際にどのスコープ (テナント / 課金アカウント / EA 登録) で
> 判定しているかは公開情報からは確認できていない。以下は「組織 = 自分がアクセスできる
> 範囲のサブスクリプション群」として調べる方法をまとめたもの。

## 難しさ: 「現存」ではなく「過去に存在した」を見る必要がある

`az redis list` は**現存するリソースしか返さない**。作って消した履歴は残らない。
したがって履歴を追える情報源を使う必要があるが、**どれも保持期間に上限がある**。

## 手段ごとの遡及範囲 (実測)

| 手段 | 遡れる範囲 | スコープ | 本サブスクでの実測 |
|------|------------|----------|--------------------|
| `az redis list` | **現在のみ** | サブスクリプション | 0 件 |
| Resource Graph `resources` | **現在のみ** | アクセス可能な全サブスク横断 | 0 件 |
| Resource Graph `resourcechanges` | **約 10 日** (実測) | 同上 | 履歴用途には短すぎる |
| **アクティビティログ** | **90 日** | サブスクリプション | 3 サブスクとも成功 0 件 |
| `az consumption usage list` | **約 1 年** (PAYG) | サブスクリプション | `Microsoft.Cache` 0 件 |
| Cost Management Query API | **13 ヶ月** | サブスク〜課金アカウント | 6 回リトライして全て 429。取得できず |
| Service Health イベント | 配信されていれば | サブスクリプション | 0 件 (※後述) |
| **実作成プローブ** | — | サブスクリプション | **確定判定** |

`resourcechanges` の保持期間は実測で確認した。

```
$ az graph query -q "resourcechanges | extend t=todatetime(properties.changeAttributes.timestamp) | summarize oldest=min(t), newest=max(t), cnt=count()"
  "oldest": "2026-09-05T13:51:00.418Z"
  "newest": "2026-09-14T23:25:13.694Z"
  "cnt": 272
```

## 具体的な調べ方

### 1. 組織の範囲を把握する

```bash
# アクセスできるサブスクリプションとテナント
az account list --all --query '[].{name:name, id:id, tenant:tenantId, state:state}' -o table

# 管理グループ配下を横断したい場合 (要 Microsoft.Management/managementGroups/read)
az account management-group list -o table
```

**注意**: `az account list` は**自分に RBAC が付いているサブスクリプションしか見えない**。
組織全体を網羅するには管理グループの Reader か課金アカウントへのアクセスが要る。
本検証環境では管理グループが権限不足で参照できなかった。

```
ERROR: (AuthorizationFailed) ... does not have authorization to perform action
'Microsoft.Management/managementGroups/read' over scope '/providers/Microsoft.Management'
```

### 2. 現存インスタンスを全サブスク横断で確認 (Resource Graph)

`az redis list` をサブスクごとに回すより速い。

```bash
az graph query -q "resources | where type =~ 'microsoft.cache/redis' | project name, subscriptionId, resourceGroup, location" -o table
```

### 3. アクティビティログで「作成に成功した記録」を探す (90 日)

**過去に作成した証跡を直接見られる唯一の手段**。ただし 90 日まで。

```bash
az monitor activity-log list --subscription <SUB_ID> --offset 89d \
  --namespace Microsoft.Cache \
  --query "[?status.value=='Succeeded' && operationName.value=='Microsoft.Cache/redis/write']" -o table
```

実際に本検証でプローブした試行も記録されていた (Started / Failed として)。

```
2026-09-15T09:17:23Z  Microsoft.Cache/redis/write  Failed   .../redis/probe-donotcreate
2026-09-15T09:17:23Z  Microsoft.Cache/redis/write  Started  .../redis/probe-donotcreate
```

`status.value == 'Succeeded'` で絞れば「実際に作成できた実績」が分かる。

### 4. 課金実績から探す (約 1 年 / 13 ヶ月)

**作成して削除済みでも、課金レコードは残る。** 90 日より長く遡れるのが利点。

```bash
# az consumption (プレビュー扱いだが利用可能)
az consumption usage list --subscription <SUB_ID> \
  --start-date 2025-09-15 --end-date 2026-09-14 --top 1000 \
  --query "length([?consumedService=='Microsoft.Cache' || consumedService=='microsoft.cache'])" -o tsv
```

Cost Management Query API (最大 13 ヶ月、課金アカウントスコープも可) も使えるが、
**429 Too Many Requests が恒常的に返る**。本検証では 30 秒間隔で 6 回リトライしても
一度も成功しなかったため、**実用上は `az consumption` を使うほうが確実**。

```bash
az rest --method post \
  --url "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --headers "Content-Type=application/json" \
  --body '{"type":"ActualCost","timeframe":"Custom",
           "timePeriod":{"from":"2025-09-01T00:00:00Z","to":"2026-09-15T00:00:00Z"},
           "dataset":{"granularity":"None",
             "aggregation":{"totalCost":{"name":"Cost","function":"Sum"}},
             "grouping":[{"type":"Dimension","name":"ServiceName"}]}}'
```

`ServiceName` に `Azure Cache for Redis` が現れれば、その期間に課金実績がある = 作成されていた。

### 5. Service Health の退役アドバイザリ (未検証の仮説)

Azure の退役通知は**影響を受けるサブスクリプションに配信される**ため、
アドバイザリが届いていれば過去に Redis を持っていた傍証になる、という仮説を立てた。

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/<SUB_ID>/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01" \
  --query "value[?properties.eventType=='HealthAdvisory'].{title:properties.title, time:properties.lastUpdateTime}" -o table
```

本検証環境ではイベント自体が 0 件だった。
**Redis を持っていたサブスクリプションが手元に無いため、この仮説は検証できていない。**
「アドバイザリがある = 過去に持っていた」の対応関係は未確認。

## 推奨する調査手順

1. **`az account list --all`** で組織の範囲を把握する
   (網羅性が要るなら管理グループ Reader か課金アカウントへのアクセスを確保)
2. **Resource Graph** で現存インスタンスを横断確認 — あればそこで確定
3. **アクティビティログ (90 日)** で成功した `Microsoft.Cache/redis/write` を探す
4. **課金実績 (約 1 年)** で `Microsoft.Cache` / `Azure Cache for Redis` を探す
5. どれも空振りなら、**実作成プローブ**で確定させる (`./check-eligibility.sh <SUB> <RG>`)

1 年より前に作成して削除済み、というケースは**上記のどの方法でも追えない**。
その場合は実作成プローブか、Microsoft サポートへの問い合わせしかない。

## 本検証環境の結果 (2026-09-15)

| サブスクリプション | テナント | 現存 | 成功した作成 (90日) | 課金実績 (過去1年) |
|---|---|:---:|:---:|:---:|
| 従量課金 `b73908f0-…` | `e1a9c1ce-…` | 0 | 0 | 0 |
| 従量課金2 `364b9914-…` | `e1a9c1ce-…` | 0 | 0 | 0 |
| ソフトバンク株式会社MSP運用 `9fc9dd20-…` | `8f259284-…` | 0 | 0 | 0 |

従量課金 `b73908f0-…` の課金実績は一括取得がタイムアウトしたため、
3 分割して確認した (いずれも 0 件)。

```
2025-09-15 〜 2025-12-31 : 0
2026-01-01 〜 2026-04-30 : 0
2026-05-01 〜 2026-09-14 : 0
```

アクセスできる範囲に Azure Cache for Redis の痕跡は無く、
実作成プローブでも `b73908f0-…` はブロックされていた。
**「組織で過去に作成したことがないためブロックされている」という説明と整合する。**

なお **`8f259284-…` (MSP 運用) は別テナント**であり、
仮にそちらで作成実績があっても `e1a9c1ce-…` 側の可否には影響しないと考えられる。


## 調査スクリプト

上記 1〜4 をまとめて実行する `check-history.sh` を用意した (すべて読み取り専用)。

```bash
./check-history.sh              # アクセス可能な全サブスクリプション
./check-history.sh <SUB_ID>     # 特定のサブスクリプションのみ
```

出力例 (2026-09-15 実測):

```
### 2. 現存する Azure Cache for Redis (Resource Graph / 全サブスク横断)
Count    Total_records
-------  ---------------
0        0

### 3. 作成履歴 (アクティビティログ 90 日 / 課金実績 約1年)
  SUBSCRIPTION                  現存   作成成功(90d)  課金実績(1y)
  従量課金                        0         0            0
  ソフトバンク株式会社MSP運用      0         0            0
  従量課金2                       0         0            0
```

`az consumption usage list` は**サブスクリプションの規模によってはタイムアウトする**。
その場合は `--start-date` / `--end-date` を 3〜4 ヶ月ずつに分割して実行する。
