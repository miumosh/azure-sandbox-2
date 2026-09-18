# 単一ゾーン -> 複数ゾーン変更で replace を避けられるか (事前調査)

`plan-zones.sh` / `try-inplace.sh` で実機確認する前の、公式仕様ベースの机上調査。
実機結果は README.md の「検証結果」に追記する。

## 結論 (先に要点)

**「単一ゾーン -> 自分で指定した複数ゾーン」への無停止変更は、どの経路でも不可能。**
in-place で変えられるのは **「-> Azure が自動で選んだゾーン冗長構成 (`zonalAllocationPolicy = Automatic`)」だけ**。

> **裏取り済み (2026-09-16)**: 公式ドキュメントに
> 「Updating an existing Standard or Premium cache to use zone redundancy is supported in-place.」
> と明記されているが、これは Automatic への片道移行を指すものであり、上記の結論とは矛盾しない。
> `UserDefined`(ゾーン番号の明示指定)への in-place 更新は同じ文書内で明確に
> 「isn't supported」とされている。引用と詳細は [doc/official-docs-zone-redundancy.md](./doc/official-docs-zone-redundancy.md) を参照。

| 経路 | in-place 変更 | ゾーンを明示指定できるか | 備考 |
|------|:---:|:---:|------|
| Terraform (`azurerm_redis_cache.zones`) | ✗ replace | ✓ 作成時のみ | `zones` は ForceNew |
| `az redis update` | ✗ | ✗ | `--zones` / `--zonal-allocation-policy` が存在しない |
| REST API `PATCH` で `zones` を直接指定 | ✗ | ✗ | Update のボディ定義に `zones` が無い |
| REST API `PATCH` で `zonalAllocationPolicy=Automatic` | **✓** | ✗ Azure が自動選択 | **唯一の in-place 経路**。不可逆 |
| ポータル「ゾーンを自動的に割り当てる」 | **✓** | ✗ Azure が自動選択 | 上と同じ API を叩いているだけ |

つまり Terraform の replace を避けたいなら、選択肢は実質

1. **ゾーン冗長化そのものを諦めずに Automatic を受け入れる** (ゾーン番号の指定は捨てる)
2. **replace を受け入れる** (再作成 + データ移行)

の二択になる。

## 経路ごとの根拠

### 1. Terraform (azurerm)

`azurerm_redis_cache` の `zones` 属性はレジストリのドキュメントに次のように書かれている。

> `zones` - (Optional) Specifies a list of Availability Zones in which this Redis Cache should be located.
> **Changing this forces a new Redis Cache to be created.**

ForceNew 属性なので、値が変われば provider は必ず「破棄 -> 再作成」を計画する。
プロバイダ側で回避するオプション (`zones` の in-place 更新) は用意されていない。

さらに azurerm は **`zonalAllocationPolicy` を未サポート**。
要望は上がっているが 2026-09 時点で未実装のまま open。

- hashicorp/terraform-provider-azurerm#28336 — *Support for zonalAllocationPolicy on azurerm_redis_cache resources* (enhancement / preview / service/redis ラベル、open)
- hashicorp/terraform-provider-azurerm#28578 — *Support for Microsoft.Cache for Redis API v2024-11-01*

このため **Terraform だけで完結する回避策は存在しない**。

### 2. az CLI

`az redis update` が受け付けるのは `--sku` / `--vm-size` と汎用の `--set` / `--add` / `--remove` のみ。
ゾーン関連のパラメータは `az redis create` 側にしかない。

```
$ az redis create --help | grep -A3 zone
    --zonal-allocation --zonal-allocation-policy : ... Allowed values: Automatic, NoZones, UserDefined.
    --zones -z                                   : Space-separated list of availability zones ...

$ az redis update --help
Arguments
    --sku               : Type of Redis cache.  Allowed values: Basic, Premium, Standard.
    --vm-size           : Size of Redis cache to deploy. ...
                          (zones / zonal-allocation-policy は無い)
```

汎用 `--set zones=...` で押し込む余地はあるが、CLI の generic update は
最終的に Update API を呼ぶだけなので、次項の理由で通らないはず — `try-inplace.sh cli` で実測する。

### 3. REST API

Update は `PATCH`、最新の API バージョンは `2024-11-01`。

```http
PATCH https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{rg}/providers/Microsoft.Cache/redis/{name}?api-version=2024-11-01
```

ここで重要なのは **リクエストボディの型が `RedisUpdateParameters` であり、`zones` を含まないこと**。

- `RedisResource` (Create/Get の型) … `zones: string[]` を **持つ**
- `RedisUpdateParameters` (Update の型) … `zones` を **持たない**。
  代わりに `properties.zonalAllocationPolicy` を持つ

`RedisUpdateParameters` で受け付けるプロパティ:

```
identity, tags,
properties.{ disableAccessKeyAuthentication, enableNonSslPort, minimumTlsVersion,
             publicNetworkAccess, redisConfiguration, redisVersion,
             replicasPerMaster, replicasPerPrimary, shardCount, sku,
             tenantSettings, updateChannel, zonalAllocationPolicy }
```

→ **API レベルで「既存キャッシュの zones を書き換える」操作そのものが定義されていない。**
Terraform が ForceNew にしているのは provider の都合ではなく、RP の仕様を反映した結果。

唯一通るのがこれ:

```http
PATCH .../providers/Microsoft.Cache/redis/{name}?api-version=2024-11-01
Content-Type: application/json

{
  "properties": {
    "zonalAllocationPolicy": "Automatic"
  }
}
```

#### `zonalAllocationPolicy` の 3 値

| 値 | 意味 | 作成時 | 更新時 |
|----|------|:---:|:---:|
| `Automatic` | Azure がリージョンの空き状況を見て自動でゾーンを割り当てる | ✓ | **✓ これだけ** |
| `UserDefined` | `zones` で指定したゾーンを使う (Premium のみ) | ✓ | ✗ |
| `NoZones` | 非ゾーン構成 (Premium のみ) | ✓ | ✗ |

2024-11-01 以降、`zonalAllocationPolicy` を省略して作成すると、
ゾーン対応リージョンでは `Automatic` が既定になる (それ以前の API バージョンでは `NoZones`)。
`zones` を渡すと `UserDefined` になる。

### 4. ポータル

「Advanced settings」->「**ゾーンを自動的に割り当てる (Allocate zones automatically)**」チェックボックス -> Save。
これは `zonalAllocationPolicy = Automatic` の PATCH を投げているだけで、経路 3 と等価。
ポータルからでも **ゾーン番号を選んで既存キャッシュに適用することはできない**。

## 制約 (Automatic を選ぶ場合に効いてくる)

公式ドキュメントに明記されている制限:

- **不可逆**: 一度 `Automatic` にすると、無効化も他の値への変更もできない
- **ゾーンを選べない**: 実際に割り当てられたゾーンは Get で `properties.instances[].zone` として確認できるだけ
- **対象ティア**: Standard / Premium のみ。Enterprise / Enterprise Flash は再作成が必要
- **非対応構成**: **geo レプリケーション構成**、**VNet インジェクション構成**のキャッシュでは、
  既存キャッシュへの Automatic 有効化が**できない**
  (この検証コードが VNet を作らず public endpoint 構成にしているのはこのため)

## Terraform との整合をどう取るか

経路 3 / 4 で Azure 側だけ変更すると、azurerm は `zonalAllocationPolicy` を知らないので
`zones` の差分だけを見て **replace を出し続ける**。落としどころは 3 つ。

| 方針 | 内容 | 代償 |
|------|------|------|
| A. `ignore_changes` | `lifecycle { ignore_changes = [zones] }` で zones を管理対象外にする | Terraform がゾーン構成を一切管理しなくなる |
| B. tfvars を実態に合わせる | Azure が割り当てたゾーンを `terraform plan` で読み取り、`redis_zones` に書き戻す | Azure 側が再割り当てすると再び差分が出る。追従が手作業 |
| C. replace を受け入れる | 素直に再作成する | ダウンタイム + データ移行 |

`redis.tf` には A のブロックをコメントアウトで置いてある。

## 補足: Azure Cache for Redis 自体が廃止予定

公式ドキュメント冒頭に退役アナウンスが出ている。

> Azure Cache for Redis announced its retirement timeline for all SKUs.
> We recommend moving your existing Azure Cache for Redis instances to Azure Managed Redis as soon as you can.

新規にゾーン構成を設計するなら、Azure Managed Redis (`azurerm_redis_enterprise_cluster` 系) 側の
ゾーン仕様も併せて確認したほうがよい。本検証のスコープ外。

## 参照

- [azurerm_redis_cache | Terraform Registry](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/redis_cache)
- [Support for zonalAllocationPolicy on azurerm_redis_cache resources · Issue #28336](https://github.com/hashicorp/terraform-provider-azurerm/issues/28336)
- [Support for Microsoft.Cache for Redis API v2024-11-01 · Issue #28578](https://github.com/hashicorp/terraform-provider-azurerm/issues/28578)
- [Redis - Update - REST API (api-version 2024-11-01)](https://learn.microsoft.com/en-us/rest/api/redis/redis/update)
- [Enable zone redundancy for Azure Cache for Redis](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-how-to-zone-redundancy)
- [Migrate an Azure Cache for Redis instance to availability zone support](https://learn.microsoft.com/en-us/azure/reliability/migrate-cache-redis)
- [High availability for Azure Cache for Redis](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-high-availability)
