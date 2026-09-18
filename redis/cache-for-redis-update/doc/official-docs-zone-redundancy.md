# 公式ドキュメント再確認: ゾーン冗長性の in-place 更新

取得日: 2026-09-16
目的: 「Updating an existing Standard or Premium cache to use zone redundancy is supported in-place.」という記述の裏取り。
`research.md` / `README.md` の結論(単一ゾーン -> ユーザー指定の複数ゾーンへの in-place 変更は不可、Automatic への片道移行のみ可能)と矛盾しないかを確認する。

> 注記: 両ページとも `ja-jp` URL でアクセスしたが、該当箇所は未翻訳で英語版の内容が返ってきた
> (フロントマターに `locale: en-us` とあり、日本語訳が存在しないためのフォールバックと見られる)。

## 1. [Enable zone redundancy for Azure Cache for Redis](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-how-to-zone-redundancy)

(ja-jp: https://learn.microsoft.com/ja-jp/azure/azure-cache-for-redis/cache-how-to-zone-redundancy)

### Automatic Zonal Allocation セクション

> Users can update their existing non-zonal or cache with manually selected zones to use Automatic Zonal Allocation by updating the cache with `ZonalAllocationPolicy` set to **Automatic**. For more information regarding the update process, see Migrate an Azure Cache for Redis instance to availability zone support.

- `ZonalAllocationPolicy` の3値: `Automatic` / `UserDefined` (Premium のみ、作成時のみ) / `NoZones` (Premium のみ、作成時のみ)
- **Important: Automatic Zonal Allocation can't be modified once enabled for a cache.** (不可逆)

### Zone Redundancy FAQ セクション (該当箇所)

> **Can I update my existing Standard or Premium cache to use zone redundancy?**
>
> - Yes, updating an existing Standard or Premium cache to use zone redundancy is supported in-place. Users can enable it by navigating to the **Advanced settings** on the Resource menu and selecting **Allocate Zones automatically** check-box followed by the save button. You can't disable zone redundancy once you enable it.
> - For more details, look into [Migrate an Azure Cache for Redis instance to availability zone support](/en-us/azure/reliability/migrate-cache-redis)
> - This can also be done by passing `ZonalAllocationPolicy` as `Automatic` in the request body while updating the cache. For more information regarding the update process using REST API, see [Update - ZonalAllocationPolicy](/en-us/rest/api/redis/redis/update#zonalallocationpolicy).
>
>   - **Updating `ZonalAllocationPolicy` to any other value than `Automatic` isn't supported.**
>
>   Important: Automatic Zonal Allocation can't be modified once enabled for a cache.
>
>   Important: Enabling Automatic Zonal Allocation for an existing cache (which is created with a different zonal allocation) is currently NOT supported for Geo Replicated caches or caches with VNet injection.

### 読み取れるポイント

- 「in-place で対応」は事実だが、対象は **`Automatic` への変更のみ**。`UserDefined`(ゾーン番号を自分で指定)への in-place 変更は明示的に「isn't supported」。
- 手順はポータルの Advanced settings -> **Allocate Zones automatically** チェックボックス -> Save。もしくは REST API PATCH で `ZonalAllocationPolicy: "Automatic"`。
- 不可逆・Geo レプリケーション/VNet インジェクション非対応、という制約は research.md の記載と一致。

## 2. [Migrate an Azure Cache for Redis instance to availability zone support](https://learn.microsoft.com/en-us/azure/redis/migrate-cache-redis-zones)

(ja-jp: https://learn.microsoft.com/ja-jp/azure/redis/migrate-cache-redis-zones)

### Enabling Zone Redundancy for Standard and Premium tiers セクション(全文)

> Updating an existing Standard or Premium cache to use zone redundancy is supported in-place. Users can enable it by navigating to the **Advanced settings** on the Resource menu and selecting **Allocate Zones automatically** check-box followed by the save button.
>
> Users can't disable zone redundancy once it's enabled.
>
> This update can also be done by passing `ZonalAllocationPolicy` as `Automatic` in the request body while updating the cache using REST API. For more information regarding the update process using REST API, see [Update - ZonalAllocationPolicy](/en-us/rest/api/redis/redis/update#zonalallocationpolicy).
>
> **Updating `ZonalAllocationPolicy` to any other value than `Automatic` isn't supported.**
>
> Important: Automatic Zonal Allocation cannot be modified once enabled for a cache.
>
> Important: Enabling Automatic Zonal Allocation for an existing cache (which is created with a different zonal allocation) is currently NOT supported for Geo Replicated caches or caches with VNet injection.

### Enterprise / Enterprise Flash 向けセクション(対比として引用)

> Currently, the only way to convert an enterprise / enterprise flash resource from non-availability zone support to availability zone support is to redeploy your current cache.
>
> Azure Cache for Redis currently doesn't allow adding availability zone support to an existing enterprise / enterprise flash cache. The best way to convert a non-zone redundant cache to a zone redundant cache is to deploy a new cache using the availability zone configuration you need, and then migrate your data from the current cache to the new cache.

- Enterprise / Enterprise Flash は in-place 不可 = 再作成必須。Standard/Premium との対比が明確。

## 結論 (裏取り結果)

**research.md / README.md の既存結論は正しい。修正不要。**

「Updating an existing Standard or Premium cache to use zone redundancy is supported in-place」は事実だが、これは:

- **できること**: 既存の非ゾーン (or ゾーン未指定) キャッシュを `ZonalAllocationPolicy = Automatic` にする、という**片道**の in-place 更新。Azure がリージョンの空き状況を見てゾーンを自動選択する。
- **できないこと**: `UserDefined`(ユーザーがゾーン番号を明示指定)への in-place 更新。公式に「isn't supported」と明記されている。単一ゾーンから「自分で指定した複数ゾーン」への無停止移行は、この文書内でも一貫して不可とされている。

したがって「再作成なしで適用できるのでは」という期待は、**「ゾーン冗長化 (Automatic) を有効にしたいだけ」なら Yes**、**「特定のゾーン番号を指定したい」なら No (再作成が必要)** という整理になる。要件がどちらかによって結論が変わるので、実際の要件(ゾーン番号を指定する必要があるか、Automatic で構わないか)を確認するとよい。

## 3. ゾーン数とコストの比較 (Automatic vs UserDefined)

取得日: 2026-09-16。追加で [High availability for Azure Cache for Redis](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-high-availability)、
[Azure Cache for Redis pricing](https://azure.microsoft.com/en-us/pricing/details/cache/)、
[Bandwidth pricing](https://azure.microsoft.com/en-us/pricing/details/bandwidth/) を参照。

### 何ゾーンに分散されるか

固定値ではなく、**ノード数 (primary + replica) に応じて Round-robin でゾーンに割り振られる**。Automatic / UserDefined で分散ロジック自体に差はない。

> Azure Cache for Redis distributes nodes in a zone redundant cache in a round-robin manner over the selected Availability Zones. It also determines the node that serves as the primary initially.

- Standard: 常に 2 ノード固定 -> 実質 2 ゾーン
- Premium (デフォルト replica 1): 2 ノード -> 2 ゾーン。replica を増やせば(最大3まで)ゾーン数も増やせる(リージョンの AZ 数が上限、通常3)
- 「ゾーン数 <= ノード数」の制約は Automatic / UserDefined 共通
- Automatic 特有の注記: 十分な空き容量がない場合、最低2ゾーンも確保できず非ゾーン構成になることがある

> In rare cases, when sufficient zone capacity is unavailable to at-least allocate two zones, and user does not pass `ZonalAllocationPolicy` in the request, Azure will create a non-zonal cache

### コスト

SKU 自体の価格は Automatic / UserDefined で**差はない**。ゾーン冗長化してもプラン料金(P1/P2 等)は変わらない。

> (pricing ページ要約) standard charges for the primary and the replica cache nodes

ゾーン冗長化に伴う追加コストは1点のみ: **primary -> replica のレプリケーショントラフィックが AZ をまたぐことで発生する network egress (帯域幅) 料金**。

> When your cache uses zone redundancy configured with multiple Availability Zones, data is replicated from the primary cache node in one zone to the other nodes in another zone. The data transfer charge is the network egress cost of data moving across the selected Availability Zones.

これは **Automatic か UserDefined かでコストの有無・単価が変わるものではない**。ノードが物理的に別 AZ にある時点で同じ課金モデルが適用される。Bandwidth pricing ページでは「同一 Availability Zone 内の転送は無料」とは明記されているが、AZ 間の具体的な $/GB 単価はページの料金表(動的テーブル)から確実に抽出できなかった。正確な単価が必要な場合は [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) で確認すること。

### Automatic と UserDefined の違い (コスト以外)

コストで差がつかないため、選定基準は運用面になる。

| 観点 | Automatic | UserDefined |
|---|---|---|
| ゾーン番号の指定 | 不可 (Azure 任せ) | 可 |
| 既存キャッシュへの適用 | in-place 可 (再作成不要) | 不可 (再作成必須) |
| 可逆性 | 不可逆 | 作成時のみ選択可 |
| コスト | AZ間レプリケーション分の egress あり | 同上 (差なし) |

「アプリと同じゾーンにキャッシュを寄せたい」という狙いで UserDefined を検討する場合でも、自動フェイルオーバーで primary/replica の役割が入れ替わるため、**どちらのゾーンが実際に primary になるかは運用中に変動する**。ゾーン固定によるレイテンシ/コスト最適化効果は限定的である点に注意。

## 参照

- [Enable zone redundancy for Azure Cache for Redis](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-how-to-zone-redundancy) (取得日 2026-09-16)
- [Migrate an Azure Cache for Redis instance to availability zone support](https://learn.microsoft.com/en-us/azure/redis/migrate-cache-redis-zones) (取得日 2026-09-16)
- [High availability for Azure Cache for Redis](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-high-availability) (取得日 2026-09-16)
- [Azure Cache for Redis pricing](https://azure.microsoft.com/en-us/pricing/details/cache/) (取得日 2026-09-16)
- [Bandwidth pricing](https://azure.microsoft.com/en-us/pricing/details/bandwidth/) (取得日 2026-09-16, AZ間の具体的単価は未確認)
