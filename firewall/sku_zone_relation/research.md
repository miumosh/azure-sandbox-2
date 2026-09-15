# Azure Firewall Premium × Japan East × ゾーン冗長 — エラー調査と回避策

対象エラー:

```
Deployment of Premium SKU firewall with the specified availability zones is currently
not supported in 'japaneast'. You may retry different availability zones settings or
a different SKU / region.
```

制約: **Premium SKU 必須 / japaneast 必須 / ゾーン冗長必須**（3 つとも変更不可）
調査日: 2026-08-26 / 調査対象サブスクリプション: `<SUBSCRIPTION_ID>`（従量課金）

---

## 1. 結論(TL;DR)

> **2026-08-26 実デプロイで検証済み。詳細は [deploy-probe.md](./deploy-probe.md)。**

- このエラーは**機能の非対応ではなく、リージョン内の特定「物理」ゾーンにおける Azure Firewall バックエンドの容量枯渇**を表す。
- **japaneast では論理ゾーン 3（本サブスクでは物理 `japaneast-az1`）が塞がっている**ことを実測で確定。ゾーン 3 を含む組み合わせは全て失敗、含まない `1,2` は成功した。
- **採るべき構成は `--zones 1 2` の 2 ゾーン Premium。** Azure Firewall の SLA は **2 ゾーン以上で 99.99%**（単一ゾーン/ゾーン指定なしは 99.95%）なので、**2 ゾーンで「ゾーン冗長」要件は満たせる**。Premium・japaneast・ゾーン冗長の 3 条件をすべて維持できる。
- **制約は SKU 依存ではなくゾーン依存**だった。Standard SKU でも `1,2,3` は同じエラーで失敗するため、「Standard で 3 ゾーン作成 → Premium へ SKU 変更」という迂回路は**成立しない**（§4.2 参照）。
- **事前検証（ARM validate / what-if / ポータルの Review+create）ではこのエラーを検出できない**（§3.5）。一方、**実 PUT での失敗は約 3 秒・プロビジョニング未開始＝無課金**で返るので、実デプロイ試行が事実上唯一かつ十分に安価な検査手段。

## 2. エラーの意味を正しく理解する

Microsoft Learn の [Azure Firewall known issues and limitations](https://learn.microsoft.com/en-us/azure/firewall/firewall-known-issues) には **"Current capacity constraints"** という表があり、リージョン × **物理ゾーン** × SKU の単位で「新規デプロイ不可」が公開されている。2026-08-20 時点の掲載例:

| Region / Zone | SKU | 内容 |
| --- | --- | --- |
| **South East Asia の物理ゾーン 3** / North Europe の物理ゾーン 2 | Standard, Premium | 新規デプロイ不可。既存 FW を停止すると**再起動できない** |
| South Central US の物理ゾーン 3 | Basic/Standard/Premium | 新規デプロイ不可 |
| Spain Central の物理ゾーン 2 | Basic/Standard/Premium | 新規デプロイ不可（〜2026-12-31 見込み） |
| West US 2 の物理ゾーン 2 | Basic/Standard/Premium | 新規デプロイ不可 |
| Qatar Central 物理ゾーン 1,2,3 | Basic/Standard/Premium | 新規デプロイ全面ブロック |
| **East US** | **Standard のみ** | Standard の新規デプロイ全面ブロック |

ポイント:

1. **SKU ごとに独立したゲート**（East US は Standard だけブロック＝Premium は可）。今回 Premium だけ蹴られるのは整合的。
2. **表記はすべて「物理ゾーン」**。デプロイ時に指定するのは「論理ゾーン」で、対応関係はサブスクリプションごとに違う（§3.2）。
3. **japaneast は 2026-08-20 版の表に未掲載**。つまり今回の事象は「まだドキュメント化されていない容量制約」か「掲載前の新規発生」。→ サポートに報告する価値がある（§4.4）。

### 過去の前例（japaneast）

[Japan Azure IaaS Core Support Blog — 東日本リージョンでの Azure Firewall のゾーン冗長に関するアナウンスの補足 (Tracking ID:7KYK-R8G)](https://jpaztech.github.io/blog/network/fw_notification_7kyk-r8g/)

- 2023-11-29 告知、2024-12-11 解消済み。
- **東日本の物理ゾーン #2** にマッピングされた論理ゾーンで Azure Firewall が構成できない事象。
- **全 SKU (Basic/Standard/Premium) が影響**。新規デプロイと既存 FW の起動の双方に影響。
- 対処: 物理ゾーン #2 にマップされる論理ゾーンを避ける / stop-start でゾーン設定を変更。

→ **今回詰まっていたのは別の物理ゾーン `japaneast-az1`（＝本サブスクの論理ゾーン 3）だった**（実測、[deploy-probe.md](./deploy-probe.md) §3.1）。
2023 年の事象と同じく**全 SKU に影響**する点は共通。エラーメッセージは要求した tier 名をそのまま埋め込むため
`Premium SKU firewall` と名指しされるが、**SKU 固有の問題ではない**ことに注意。

---

## 3. 事前調査方法（CLI・実行結果つき）

### 3.1 リソースタイプ単位のゾーン対応を見る

```bash
az provider show -n Microsoft.Network -o json \
  --query "resourceTypes[?resourceType=='azureFirewalls'].zoneMappings|[0]" \
| python3 -c "import sys,json;[print(e['location'],e['zones']) for e in json.load(sys.stdin)]"
```

実行結果（抜粋）:

```
Japan East      ['3', '1', '2']
Japan West      ['3', '1', '2']
East Asia       ['3', '1', '2']
Korea Central   ['3', '1', '2']
Southeast Asia  ['3', '1', '2']
```

**Japan East は論理ゾーン 1/2/3 すべてが `azureFirewalls` の対象**。
→ ただしこれは**リソースタイプ単位のメタデータで、SKU 別の容量は反映されない**。「対応している」＝「今デプロイできる」ではない。**一次スクリーニング用**と割り切る。

### 3.2 論理ゾーン ⇔ 物理ゾーンのマッピングを取る（最重要）

Known issues 表は物理ゾーン表記なので、自分のサブスクの対応表がないと読めない。

```bash
SUB=$(az account show --query id -o tsv)
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/locations?api-version=2022-12-01" \
| python3 -c "
import sys,json
for v in json.load(sys.stdin)['value']:
    if v['name']=='japaneast':
        for m in v['availabilityZoneMappings']:
            print('論理', m['logicalZone'], '->', m['physicalZone'])
"
```

**本サブスクリプション（`<SUBSCRIPTION_ID>`）の japaneast 実測結果:**

| 論理ゾーン（デプロイ時に指定する値） | 物理ゾーン（ドキュメントの表記） | Azure Firewall 実測（2026-08-26） |
| --- | --- | --- |
| **1** | `japaneast-az2`（2023 年に容量制約が出た物理ゾーン） | ✅ 利用可 |
| **2** | `japaneast-az3` | ✅ 利用可 |
| **3** | `japaneast-az1` | ❌ **容量不足（Basic/Standard/Premium 共通）** |

参考（同時取得）: japanwest / eastus / southeastasia も同じく `1→az2, 2→az3, 3→az1`。

> **注意**: このマッピングは**サブスクリプションごとに異なる**。他サブスクや他テナントで得た「ゾーン N はダメだった」という情報を、そのまま論理ゾーン番号で流用してはいけない。必ず物理ゾーン名に変換して比較すること。

### 3.3 Known issues 表を自分のサブスクの論理ゾーンに翻訳する

上表を使うと、本サブスクでは:

- 「物理ゾーン #2 が使えない」 → **論理ゾーン 1 を外す** → `--zones 2 3`
- 「物理ゾーン #1 が使えない」 → 論理ゾーン 3 を外す → `--zones 1 2`
- 「物理ゾーン #3 が使えない」 → 論理ゾーン 2 を外す → `--zones 1 3`

### 3.4 Service Health / Resource Health を見る

```bash
SUB=$(az account show --query id -o tsv)
az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&\$filter=Properties/EventType%20eq%20'ServiceIssue'%20or%20Properties/EventType%20eq%20'HealthAdvisory'"
```

実行結果: `events: 0`（本サブスクに紐づく告知なし）。
2023 年の事象は Tracking ID 付きの Service Health 告知として配信されたので、**ポータルの Service Health → Health advisories** も併せて確認する価値がある（CLI に出ないケースあり）。

### 3.5 ⚠ ARM の事前検証ではこの制約を検出できない（実測）

「デプロイ前に安全に試す」目的で ARM の preflight validation を回したが、**全ゾーン組み合わせで検証が通ってしまった**。

検証に使ったテンプレート: `fw-zone-probe.json`（同ディレクトリ）— VNet + zone-redundant Public IP + Premium ポリシー + Premium Firewall の一式。

```bash
for Z in '["1","2","3"]' '["1","2"]' '["1","3"]' '["2","3"]' '["1"]' '["2"]' '["3"]'; do
  az deployment group validate -g <RG> --template-file fw-zone-probe.json \
     --parameters zones="$Z" tier=Premium prefix=zprobe -o none && echo "zones=$Z OK"
done
```

実行結果:

```
Premium zones=["1","2","3"]  => VALIDATE OK
Premium zones=["1","2"]      => VALIDATE OK
Premium zones=["1","3"]      => VALIDATE OK
Premium zones=["2","3"]      => VALIDATE OK
Premium zones=["1"]          => VALIDATE OK
Premium zones=["2"]          => VALIDATE OK
Premium zones=["3"]          => VALIDATE OK
```

**結論: `az deployment group validate` / `what-if` / ポータルの Review+create は容量ゲートを見ていない。** 容量チェックは実際の PUT（プロビジョニング）時に Network RP 側で行われる。**事前に確実に知る API は存在しない**と考えてよい。

（参考: `az vm list-skus -l japaneast` のゾーン制限を見る手もあるが、Azure Firewall のバックエンド VMSS はサービス管理でユーザーのクォータ/SKU 空きとは別プール。当環境では出力が巨大で OOM したため実行せず。相関は保証されないので**参考にとどめる**。）

### 3.6 実デプロイ・プローブ（唯一確実な判定手段）

**失敗したデプロイには課金が発生しない**ので、ゾーン組み合わせを変えて短時間で試すのが最短ルート。

japaneast の実勢価格（Retail Prices API, JPY, 2026-08-26 取得）:

| メーター | 単価 |
| --- | --- |
| Premium Deployment | **286.80 円 / 時間** |
| Premium Capacity Unit | 18.03 円 / 時間 |
| Premium Data Processed | 2.62 円 / GB |

→ **成功してしまった場合でも 1 時間以内に削除すれば数百円**。試行コストはほぼ無視できる。

プローブ手順:

```bash
RG=rg-fw-zoneprobe
# 1) 事前に VNet(AzureFirewallSubnet /26) と zone-redundant Public IP を作っておく（§5.3 の落とし穴に注意）
# 2) ゾーン組み合わせを変えて firewall だけを作成し、成否を記録
for Z in "2 3" "1 3" "1 2" "1 2 3"; do
  echo "=== zones: $Z ==="
  az network firewall create -g $RG -n probe-afw -l japaneast \
     --sku AZFW_VNet --tier Premium --firewall-policy <policy-id> --zones $Z \
     && { echo "SUCCESS with zones=$Z"; break; }
  az network firewall delete -g $RG -n probe-afw 2>/dev/null
done
```

記録すべきもの: 失敗時の **`x-ms-correlation-request-id` / タイムスタンプ / 指定ゾーン**（サポート起票時に必須）。
`az ... --debug` で取得できる。

---

## 4. 回避策（優先順）

### 4.1 【採用】ゾーンを 2 つに減らす — 3 条件すべて維持できる ✅ 実測で成立確認

- Azure Firewall の SLA: **2 ゾーン以上 = 99.99% / 単一ゾーンまたはゾーン指定なし = 99.95%**。
  → **2 ゾーンでも「ゾーン冗長」要件・99.99% SLA を満たす。**
- **実測結果（2026-08-26）**: `1,2` のみ成功。`2,3` / `1,3` / `1,2,3` / `3` は全て失敗。
  → **`--zones 1 2`（物理 `japaneast-az2` + `japaneast-az3`）が唯一のゾーン冗長構成。**
- 3 ゾーン全部が必須要件でないなら、これが最もコスト・リードタイムの小さい解。

### 4.2 【❌ 実測で否定】Standard SKU で 3 ゾーン作成 → Change SKU で Premium へ昇格

> **結論: 本件では成立しない。**
> Standard SKU + `zones 1,2,3` を実際にデプロイしたところ、**Premium と全く同じ `AzureFirewallUnsupportedAvailabilityZone` で失敗**した
> （[deploy-probe.md](./deploy-probe.md) §4）。今回の japaneast の容量制約は **SKU 単位ではなくゾーン単位**で、全 SKU に影響する。

以下は「SKU 単位のゲートだった場合」に有効な手順として記録（East US の Standard-only ブロックのような事例では有効）:

- [Change Azure Firewall SKU](https://learn.microsoft.com/en-us/azure/firewall/change-sku) の **Easy SKU change**（ポータル / PowerShell の `sku_tier` 変更 / Terraform）は **Standard → Premium をゼロダウンタイム**でサポート。ファイアウォールポリシー利用が前提（Classic ルール不可）。既存 Standard ポリシーは自動で Premium ポリシーに複製・昇格される。
- **ゾーン設定は SKU 変更で維持される**（zones は FW リソースのプロパティで、SKU tier とは独立）。
- **az CLI には tier 変更のオプションがない**（`az network firewall update` に `--tier` なし）。ポータル / PowerShell / Terraform / `az rest` の PUT を使う。
- Easy SKU change が使えず Manual migration（deallocate → `$azfw.Sku.Tier="Premium"` → allocate、ダウンタイム 20〜30 分）になる場合、**allocate 時に容量ゲートに当たると停止したまま起動不能になるリスク**がある。本番では避けること。

### 4.3 【並行実施】Azure サポートに起票して容量割当をリクエスト

japaneast が公式の capacity constraints 表に**載っていない**ため、**報告の価値が高い**。以下を添えて起票:

- エラーメッセージ全文、指定した論理ゾーン、**論理→物理のマッピング表（§3.2）**、correlation request ID、発生時刻（UTC）、サブスクリプション ID
- 業務要件（Premium / japaneast / ゾーン冗長がいずれも必須である旨）
- 依頼内容: 「japaneast の Premium SKU について、どの物理ゾーンが利用可能かの開示」と「必要なら容量の割当」

問い合わせ種別: *Azure Firewall* → *Deployment / Configuration*（Technical）。

### 4.4 【要件が許すなら】vWAN Secured Virtual Hub 上の Azure Firewall Premium

- Secured Hub の Firewall は別の配置パスを通るため、VNet Hub 型とは容量状況が異なる場合がある。
- 制約: **Secured Hub では可用性ゾーンをデプロイ時にしか設定できない**（後から変更不可・仕様）。
- ハブ&スポーク設計を vWAN に変える必要があるため、影響が大きい。要件が VNet Hub 固定なら不可。

### 4.5 【時間で解ける可能性】リトライ

容量は時間とともに変動する。2023 年の japaneast 事象は約 1 年で解消した一方、West US 2 のように長期化する例もある。**恒久策として当てにしない**。デプロイパイプラインには失敗時にゾーン組み合わせをフォールバックする仕組みを入れておくとよい。

### 4.6 【効果限定的】別サブスクリプションで試す

論理↔物理マッピングはサブスク単位で違うので、**論理ゾーン番号の意味が変わる**。ただし **3 ゾーン全指定なら物理ゾーンは全部含まれるので意味がない**。2 ゾーン運用で「どの物理ゾーンを掴むか」を制御したい場合にのみ有効。

### 4.7 採用しない案（要件と衝突）

| 案 | 却下理由 |
| --- | --- |
| ゾーン指定なしでデプロイ | ゾーン冗長要件を満たさない（SLA 99.95%） |
| Standard / Basic のまま運用 | Premium 必須要件を満たさない |
| japanwest / 他リージョンへ | japaneast 必須要件を満たさない |

---

## 5. 落とし穴・注意点

### 5.1 停止すると起動できなくなるリスク

known issues の警告（原文要旨）: **容量制約のあるリージョンで既存 Azure Firewall を停止すると、容量不足により再起動できない場合がある。** japaneast が制約下にある今、**既存 FW の deallocate は絶対に避ける**。

### 5.2 ゾーン設定は「後から変更可能」（ただし PowerShell のみ・停止を伴う）

[Azure Firewall FAQ — How can I configure availability zones after deployment?](https://learn.microsoft.com/en-us/azure/firewall/firewall-faq) より、以下の条件下で後から再構成できる:

- FW が **VNet にデプロイされている**（Secured Virtual Hub は不可）
- リージョンが可用性ゾーンをサポートしている
- **アタッチされている全 Public IP が同じゾーン構成である**

```powershell
# 停止
$azfw = Get-AzFirewall -Name "FW" -ResourceGroupName "RG"
$azfw.Deallocate(); Set-AzFirewall -AzureFirewall $azfw
# ゾーンを変えて起動
$azfw = Get-AzFirewall -Name "FW" -ResourceGroupName "RG"
$vnet = Get-AzVirtualNetwork -ResourceGroupName "RG" -Name "VNet"
$pip  = Get-AzPublicIpAddress -ResourceGroupName "RG" -Name "azfwpublicip"
$azfw.Allocate($vnet, $pip)
$azfw.Zones = 1,2,3
Set-AzFirewall -AzureFirewall $azfw
```

**az CLI にこの操作はない（PowerShell 専用）。** かつ §5.1 のリスクを伴う。

### 5.3 ゾーン指定 FW には「事前作成済みの zone-redundant Public IP」が必要

known issues:
> **Can't deploy Firewall with Availability Zones with a newly created Public IP address** — First create a new zone redundant Public IP address, then assign this previously created IP address during the Firewall deployment.

→ **Public IP と Firewall を同一 ARM デプロイで一括作成すると、ゾーン指定時に失敗しうる。** Public IP を先に単独で作成（Standard SKU・zones 1,2,3）してから Firewall を作ること。今回のエラーとは文言が違うが、**同じテンプレートで両方作っていたなら副次的な失敗要因になり得るので切り分けること**。

### 5.4 停止/起動でプライベート IP が変わる

deallocate → allocate で AzureFirewallSubnet から動的に払い出し直されるため、**UDR の next hop を再設定する必要がある**。SKU 変更を manual migration で行う場合の実務上の最大の落とし穴。

### 5.5 Premium 特有

- Premium は IDPS / TLS インスペクションのため **より強力な VM SKU** を使う（＝そのぶん容量が逼迫しやすい）。これが「Premium だけ蹴られる」構造的な理由。
- Premium ポリシーは Standard FW にアタッチできない（ダウングレード時の制約）。

---

## 6. 推奨アクションプラン

調査・検証は完了済み（[deploy-probe.md](./deploy-probe.md)）。残りは意思決定と本番適用のみ。

| # | 作業 | 状態 |
| --- | --- | --- |
| 1 | 論理⇔物理ゾーンのマッピング取得（§3.2） | ✅ 完了（1→az2, 2→az3, 3→az1） |
| 2 | ゾーン組み合わせの実デプロイ検証 | ✅ 完了（`1,2` のみ可） |
| 3 | Standard 経由の 3 ゾーン確保が可能かの検証 | ✅ 完了（**不可**） |
| 4 | **本番サブスクで §3.2 のマッピングを取得**（サブスクごとに論理番号が変わる） | ⬜ 要実施・1 分 |
| 5 | **`--zones 1 2` で Premium を本番デプロイ**（物理 az2 + az3 を掴む論理ゾーンを指定） | ⬜ 要実施・10 分 |
| 6 | 「ゾーン冗長 = 2 ゾーン（SLA 99.99%）」で要件充足とする合意・記録 | ⬜ 要実施 |
| 7 | 3 ゾーンが絶対要件なら §4.3 のサポート起票（物理 `japaneast-az1` の容量開放依頼） | ⬜ 任意 |
| 8 | 3 ゾーン化を待つ場合、§5.2 の手順で後からゾーン追加（停止を伴う・§5.1 のリスクあり） | ⬜ 将来 |

> **本番サブスクでは論理ゾーン番号が変わる可能性がある。** 塞がっているのは物理 `japaneast-az1` なので、
> 本番サブスクのマッピングを取得し、**`japaneast-az2` と `japaneast-az3` にマップされる 2 つの論理ゾーン**を指定すること。
> 本サブスクと同じマッピングなら `--zones 1 2`。

**判断基準**: 「ゾーン冗長 = 3 ゾーン」と社内定義しているなら、**「2 ゾーン以上（SLA 99.99%）」に緩められないか**を先に関係者と握るのが最短。Azure 公式 SLA も 2 ゾーンで 99.99% であり、3 ゾーンにしても数値は変わらない。現状 japaneast では 3 ゾーン構成は**どの SKU でも作成不可**なので、待つ以外の選択肢はない。

---

## 7. 参考リンク

- [Azure Firewall known issues and limitations — Current capacity constraints](https://learn.microsoft.com/en-us/azure/firewall/firewall-known-issues)
- [Change Azure Firewall SKU（Easy SKU change / Manual migration）](https://learn.microsoft.com/en-us/azure/firewall/change-sku)
- [Azure Firewall FAQ — How can I configure availability zones after deployment?](https://learn.microsoft.com/en-us/azure/firewall/firewall-faq)
- [Reliability in Azure Firewall](https://learn.microsoft.com/en-us/azure/reliability/reliability-firewall)
- [SLA for Azure Firewall](https://www.azure.cn/en-us/support/sla/azure-firewall/)
- [Deploy an Azure Firewall with Availability Zones using Azure PowerShell](https://learn.microsoft.com/en-us/azure/firewall/deploy-availability-zone-powershell)
- [Availability zones — Physical and logical availability zones](https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview#physical-and-logical-availability-zones)
- [JP Azure IaaS Core Support Blog — 東日本リージョンでの Azure Firewall のゾーン冗長に関するアナウンスの補足 (7KYK-R8G)](https://jpaztech.github.io/blog/network/fw_notification_7kyk-r8g/)
- [Multiple firewall deployments (Premium and Standard) failing in Central US — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5752416/multiple-firewall-deployments-(premium-and-standar)
- [SKU not available errors — Azure Resource Manager](https://learn.microsoft.com/en-us/azure/azure-resource-manager/troubleshooting/error-sku-not-available)
