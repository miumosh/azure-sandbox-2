# Azure Cache for Redis のゾーン変更 (単一ゾーン -> 複数ゾーン) 検証

Premium の Azure Cache for Redis を**単一ゾーン**で作り、そこから**複数ゾーン**に変えたときに

1. Terraform の plan が `replace` (破棄 -> 再作成) になることの実証
2. `replace` を避ける経路が無いかの探索 — **CLI / REST API / ポータル**

を実機で確認する。

> ## ⚠ 現状: このサブスクリプションでは実機検証できない
>
> 2026-09-15 時点で、**Azure Cache for Redis の新規作成が RP 側でブロックされている**
> ことが判明した (`400 BadRequest: Azure Cache for Redis is retiring`)。
> そのため本ディレクトリの Terraform は **apply できない**。
>
> - 判定方法の調査結果 -> [creation-eligibility.md](./creation-eligibility.md)
> - 作成可否の確認 -> `./check-eligibility.sh`
> - 組織での過去の作成履歴を調べる -> `./check-history.sh`
> - **作成できる別環境で試すコード -> [create-redis-single-az/](./create-redis-single-az/)**
>
> **机上調査の結論 ([research.md](./research.md)) は実機確認なしでも有効**。
> 「なぜ replace になるか / 回避できるか」は ARM API の型定義から確定しており、
> 実機検証は裏取りにすぎないため。


> 事前の机上調査 (公式仕様ベース) は [research.md](./research.md) にまとめてある。
> 先に結論を知りたい場合はそちらを参照。

## 構成

| リソース | 内容 |
|----------|------|
| `redisaz-rg` | 検証用リソースグループ (japaneast) |
| `redis-redisaz-<suffix>` | Azure Cache for Redis **Premium P1** / replica 1 / public endpoint |

- **Premium を使う理由**: `zones` を明示指定できるのは Premium のみ。
  Standard は Azure による自動割り当て (`Automatic`) 固定で、ゾーン番号を選べない。
- **VNet インジェクションを使わない理由**: VNet 注入されたキャッシュは、
  後述の `zonalAllocationPolicy = Automatic` への in-place 変更が**非対応**のため。
  回避策の検証ができなくなるので public endpoint 構成にしてある。
- **ゾーン数 <= ノード数**の制約がある。既定の `replicas_per_master = 1` では
  primary + replica = 2 ノードなので**指定できるゾーンは最大 2 つ**。
  3 ゾーン試したい場合は `locals.tf` の `replicas_per_master` を 2 に上げる。

## 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id を記入
terraform init

# 1. 単一ゾーンで作成 (Premium の作成は 20〜30 分ほどかかる)
terraform apply

# 2. 複数ゾーンに変えて plan が replace になることを確認
./plan-zones.sh '["1","2"]'

# 3. replace を避ける経路を試す
./try-inplace.sh show        # 現在の zones / zonalAllocationPolicy
./try-inplace.sh cli         # az CLI で zones を変えられるか
./try-inplace.sh api-zones   # REST API で zones を直接 PATCH してみる
./try-inplace.sh api-auto    # REST API で zonalAllocationPolicy=Automatic  ★不可逆
```

`./try-inplace.sh api-auto` は **一度実行すると元に戻せない**ため確認プロンプトが入る。
実行後は自動で `terraform plan` まで流して、Terraform 側にどんな差分が残るかを表示する。

各コマンドの生の応答は `out/` に保存される (リソース ID を含むため git 管理外)。

### 後片付け

```bash
terraform destroy
```

## 検証のポイント

### なぜ `zones` の変更が replace になるのか

`azurerm_redis_cache` の `zones` は **ForceNew 属性**だが、これは provider の都合ではなく
**ARM の RP 仕様をそのまま反映したもの**。Update API (`PATCH`) のリクエストボディ型
`RedisUpdateParameters` には、そもそも `zones` フィールドが存在しない。

| API の型 | `zones` | `zonalAllocationPolicy` |
|----------|:---:|:---:|
| `RedisResource` (Create / Get) | ✓ | ✓ |
| `RedisUpdateParameters` (Update) | **✗** | ✓ |

つまり「既存キャッシュの zones を書き換える」操作は**API として定義されていない**。
Terraform を経由しようが CLI を経由しようが、この壁は越えられない。

### in-place で変えられる唯一の経路

`properties.zonalAllocationPolicy` を `Automatic` にする PATCH だけが通る。

```bash
az rest --method patch \
  --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Cache/redis/<name>?api-version=2024-11-01" \
  --headers "Content-Type=application/json" \
  --body '{"properties":{"zonalAllocationPolicy":"Automatic"}}'
```

ポータルの「Advanced settings」->「ゾーンを自動的に割り当てる」チェックボックスも、
内部的にはこれと同じリクエストを投げているだけ。

ただし **ゾーン番号は指定できない**。Azure がリージョンの空き状況を見て自動で選ぶ。
実際に割り当てられたゾーンは Get の `properties.instances[].zone` で確認できる。

**したがって「単一ゾーン -> 自分で指定した複数ゾーン」を無停止で実現する方法は無い。**
in-place でできるのは「-> Azure 自動割り当てのゾーン冗長」への片道移行だけ。

### `Automatic` の制約

- **不可逆** — 無効化も他の値への変更もできない
- **ゾーンを選べない** — Azure 任せ
- **Standard / Premium のみ** — Enterprise / Enterprise Flash は再作成が必要
- **geo レプリケーション構成 / VNet インジェクション構成では使えない**

### Terraform との整合

azurerm は `zonalAllocationPolicy` を**サポートしていない** (要望 [#28336](https://github.com/hashicorp/terraform-provider-azurerm/issues/28336) は open)。
そのため API / ポータルで `Automatic` に変えると、Terraform は `zones` の差分だけを見て
**replace を出し続ける**。落としどころは 3 つ。

| 方針 | 内容 | 代償 |
|------|------|------|
| A. `ignore_changes` | `lifecycle { ignore_changes = [zones] }` | Terraform がゾーン構成を管理しなくなる |
| B. tfvars を実態に合わせる | 割り当てられたゾーンを `redis_zones` に書き戻す | Azure 側の再割り当てに手作業で追従が必要 |
| C. replace を受け入れる | 素直に再作成する | ダウンタイム + データ移行 |

A のブロックは `redis.tf` にコメントアウトで置いてある。

### C (replace を受け入れる) を選ぶ場合の影響範囲

ホスト名は変わらないが **アクセスキーは変わる**、**25〜40 分のダウンタイムが発生する**、
セッション / ジョブキュー / 分散ロックに使っていると影響が大きい、など
事前に押さえておくべき点を [doc/recreation-impact.md](./doc/recreation-impact.md) にまとめた。

## 検証結果

### 0. そもそも作成できなかった (2026-09-15 実測)

`terraform apply` は Redis キャッシュの作成時点で失敗した。

```
azurerm_resource_group.this: Creation complete after 23s
azurerm_redis_cache.this: Creating...

Error: creating Redis (Subscription: "b73908f0-..." / Redis Name: "redis-redisaz-2bkrnk"):
performing RedisCreate: unexpected status 400 (400 Bad Request) with error:
BadRequest: Azure Cache for Redis is retiring, create Azure Managed Redis instance instead.
Learn more: https://aka.ms/AzureCacheForRedisRetirement
```

- 作成されたのは RG のみ。キャッシュは未作成で課金は発生していない
- **Premium P1 / Basic C0 のどちらでも同じ** = ティアではなくサブスクリプション単位の制限
- 検証に使ったサブスクリプションは Azure Cache for Redis を 1 つも持っておらず、
  「新規顧客」扱いでブロックされたと考えられる

詳細と判定方法は [creation-eligibility.md](./creation-eligibility.md) にまとめた。

### 1〜4. ゾーン変更の実機検証 — 未実施

上記の理由で実施できていない。実機で確認できるサブスクリプションが用意でき次第、
`./plan-zones.sh` / `./try-inplace.sh` を流してここに追記する。

**ただし結論自体は [research.md](./research.md) で確定している。**
Update API のリクエストボディ型 `RedisUpdateParameters` に `zones` フィールドが
存在しないという仕様レベルの事実が根拠であり、実機確認に依存しない。

## 注意: Azure Cache for Redis は廃止予定

公式ドキュメントに全 SKU の退役タイムラインが出ており、Azure Managed Redis への移行が推奨されている。
新規にゾーン構成を設計する場合は Azure Managed Redis 側の仕様も確認すること (本検証のスコープ外)。

## ファイル

| ファイル | 内容 |
|----------|------|
| `providers.tf` | provider / version 固定 |
| `variables.tf` | `subscription_id` / `location` / **`redis_zones` (主スイッチ)** |
| `locals.tf` | 命名・SKU などの設定値 |
| `redis.tf` | RG + Redis キャッシュ本体 |
| `outputs.tf` | 検証スクリプトが参照する出力 |
| `plan-zones.sh` | zones を変えて plan し、replace かどうかを判定 |
| `try-inplace.sh` | CLI / REST API での in-place 変更を試す |
| `research.md` | 公式仕様ベースの事前調査 |
| `creation-eligibility.md` | **作成可否の判定方法の調査結果** |
| `check-eligibility.sh` | サブスクリプションで作成できるかを判定 |
| `check-history.sh` | 組織で過去に作成した履歴があるかを調査 (読み取り専用) |
| `create-redis-single-az/` | **作成可能な別環境用**: Premium / 単一 AZ を作る最小構成 |
| `doc/recreation-impact.md` | **再作成 (replace) が発生したときの影響範囲** |
| `.gitignore` | このディレクトリ単体でも `terraform.tfvars` を除外する |
