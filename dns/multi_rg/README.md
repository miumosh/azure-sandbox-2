# 同名 Private DNS ゾーンをマルチ RG に置いたときの名前解決検証

単一サブスクリプション内に RG を 3 つ作り、**まったく同じ名前の Private DNS ゾーン
(`privatelink.blob.core.windows.net`) を RG1 / RG2 の両方に作成**して、

1. 同名ゾーンを別 RG に作れるか
2. 名前解決は衝突するか

を実機で確認する。

## 構成

| RG | VNet | 内容 |
|----|------|------|
| `dnsmrg-rg1` | `vnet-dnsmrg-1` (10.10.0.0/16) | Storage + Private Endpoint (10.10.1.4)、Private DNS ゾーン A |
| `dnsmrg-rg2` | `vnet-dnsmrg-2` (10.20.0.0/16) | Storage + Private Endpoint (10.20.1.4)、Private DNS ゾーン B (**A と同名**) |
| `dnsmrg-rg3` | `vnet-dnsmrg-3` (10.30.0.0/16) | 確認用 Ubuntu VM |

- 3 VNet はフルメッシュでピアリング済み (6 リンク)
- ゾーン A は VNet1 に、ゾーン B は VNet2 に固定リンク
- **VNet3 (VM 側) にどちらのゾーンをリンクするかを `var.vm_vnet_dns_link` で切り替える** — これが検証の主スイッチ
- 両ゾーンに同名・別 IP の A レコード `conflict.privatelink.blob.core.windows.net` を配置
  (RG1→`10.10.99.99` / RG2→`10.20.99.99`)。Storage の FQDN はグローバル一意で
  ゾーン間で重ならないため、「同一 FQDN の解決先が食い違う」様子を見るために追加している。

## 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id を記入
terraform init
terraform apply

./verify.sh          # VM 上で dig を実行 (SSH 不要 / az vm run-command 経由)
./switch.sh rg2      # VNet3 のリンク先ゾーンを切り替えて再確認
./switch.sh both     # 同名ゾーンの二重リンクを試す (失敗するのが期待値)

# 両ゾーンからレコード名の重複を無くしたうえで二重リンクを試す
terraform apply -var create_conflict_records=false
terraform apply -var create_conflict_records=false -var vm_vnet_dns_link=both
```

`switch.sh` が `none` を経由する 2 段階 apply になっているのは、rg1↔rg2 を 1 回の
apply で入れ替えると Terraform が旧リンク削除と新リンク作成を並列に投げてしまい、
削除完了前に作成が走って後述の overlapping namespaces エラーになるため。

## 検証結果

### 1. 同名 Private DNS ゾーンは別 RG に作成できる → **できる**

Private DNS ゾーンは RG スコープのリソースで、名前の一意性も RG 単位。
同一サブスクリプション内に同名ゾーンが 2 つ併存した。

```
rg1 = /subscriptions/.../resourceGroups/dnsmrg-rg1/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net
rg2 = /subscriptions/.../resourceGroups/dnsmrg-rg2/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net
```

### 2. 同じ VNet に同名ゾーンを 2 つリンクすることはできない → **API が拒否する**

`./switch.sh both` の実行結果 (Status: BadRequest)。

```
A virtual network cannot be linked to multiple zones with overlapping namespaces.
You tried to link virtual network with 'privatelink.blob.core.windows.net'
and 'privatelink.blob.core.windows.net' zones.
```

つまり **「衝突」は名前解決の実行時ではなくリンク作成時に弾かれる**。
1 つの VNet から見える同名ゾーンは常に高々 1 つで、どちらが優先されるかという
曖昧な状態は原理的に発生しない。

### 2-a. レコード名が重複していなくてもリンクは失敗する

「同名ゾーンでも、中の A レコード名が被っていなければリンクできるのでは」を実測で確認した。
`var.create_conflict_records = false` にして手動 A レコードを削除し、各ゾーンに
**自分の Private Endpoint が登録した A レコード (ストレージ名 = グローバル一意) だけ**
が存在する = 2 ゾーン間でレコード名が一切重複しない状態を作る。

```
$ az network private-dns record-set list -g dnsmrg-rg1 -z privatelink.blob.core.windows.net
@                 SOA
stdnsmrg1sce2ap   A
$ az network private-dns record-set list -g dnsmrg-rg2 -z privatelink.blob.core.windows.net
@                 SOA
stdnsmrg2sce2ap   A
```

この状態で二重リンクを試しても、**エラーはレコードがあった場合とまったく同じ**。

```
$ terraform apply -var create_conflict_records=false -var vm_vnet_dns_link=both

Error: creating Virtual Network Link (Subscription: "...", Resource Group Name: "dnsmrg-rg1",
Private Dns Zone Name: "privatelink.blob.core.windows.net",
Virtual Network Link Name: "link-vnet3-from-rg1"): polling after CreateOrUpdate:
polling failed: the Azure API returned the following error:

Status: "BadRequest"
Message: "A virtual network cannot be linked to multiple zones with overlapping namespaces.
You tried to link virtual network with 'privatelink.blob.core.windows.net'
and 'privatelink.blob.core.windows.net' zones."

API Response:
{"error":{"code":"BadRequest","message":"A virtual network cannot be linked to multiple zones
with overlapping namespaces. You tried to link virtual network with
'privatelink.blob.core.windows.net' and 'privatelink.blob.core.windows.net' zones."},
"status":"Failed"}
```

**判定はゾーンの名前空間単位で、中身のレコードは一切見ていない。**
ゾーンが空でも、レコードが完全に住み分けていても結果は変わらない。

### 2-b. 「overlapping」は完全同名のみ。親子関係のゾーンは共存できる

エラー文言が "overlapping namespaces" のため、親子関係 (サブドメイン) のゾーンも
弾かれるのかを確認した。VNet3 に `privatelink.blob.core.windows.net` がリンク済みの状態で、
`sub.privatelink.blob.core.windows.net` を作って同じ VNet3 にリンクする。

```
$ az network private-dns zone create -g dnsmrg-rg1 -n sub.privatelink.blob.core.windows.net
$ az network private-dns link vnet create -g dnsmrg-rg1 \
    -z sub.privatelink.blob.core.windows.net -n link-child-test -v <vnet3-id> -e false
  -> 成功 (エラーなし)
```

つまり **overlapping = 完全同名** であり、親子ゾーンは同一 VNet に共存できる。
弾かれるのは「同じ FQDN に対して権威が 2 つ生まれる」ケースだけ。
(この確認用ゾーンは検証後に削除済み。Terraform 管理外。)

### 補足: 同名ゾーンのどちらにリンクするかは何で決まるか

`azurerm_private_dns_zone_virtual_network_link` には **ゾーンを ID で指す引数が存在しない**。
スキーマ上の必須引数は次の 4 つだけ。

| 引数 | 役割 |
|------|------|
| `name` | リンク自身の名前 |
| `private_dns_zone_name` | 対象ゾーン名 (同名なので判別には効かない) |
| `resource_group_name` | **対象ゾーンが属する RG。ここが唯一の判別要素** |
| `virtual_network_id` | リンクする VNet (こちらは完全な ID) |

VNet リンクは Azure 上ではゾーンの**子リソース**であり、リソース ID が
`.../resourceGroups/<zone-rg>/providers/Microsoft.Network/privateDnsZones/<zone>/virtualNetworkLinks/<link>`
という階層になる。この親パスを組み立てているのが `resource_group_name` + `private_dns_zone_name`。

実際に生成された ID (同名ゾーンだが RG 部分だけが違う):

```
.../resourceGroups/dnsmrg-rg1/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net/virtualNetworkLinks/link-rg1-own
.../resourceGroups/dnsmrg-rg2/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net/virtualNetworkLinks/link-rg2-own
```

**注意点**: この `resource_group_name` は「リンクしたい VNet の RG」ではなく
「**ゾーン側の RG**」である。本構成の `dns.tf` でも、VNet3 (rg3) へのリンクなのに
`resource_group_name = azurerm_resource_group.this["rg1"].name` と書いている。
同名ゾーンが複数ある環境では、ここを取り違えても Terraform も Azure もエラーを出さず、
**意図と違うゾーンに黙って紐づく**。同名ゾーン運用で最も事故りやすいのがこの引数。

なお、Private Endpoint 側の `private_dns_zone_group` は対照的に
`private_dns_zone_ids` で完全な ID を受け取るため曖昧さがない。

```
private_dns_zone_ids = [
  ".../resourceGroups/dnsmrg-rg2/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net",
]
```

### 3. VNet ごとに解決結果が変わる / ピアリングは DNS を伝播しない

VM (VNet3) からの `dig` 結果。VNet3 にリンクしたゾーンだけが効いている。

| FQDN | link = `rg1` | link = `rg2` | link = `none` |
|------|--------------|--------------|----------------|
| RG1 の Storage | **10.10.1.4** (PE) | CNAME 止まりで解決不可 | パブリック IP <STORAGE_PUBLIC_IP_1> |
| RG2 の Storage | CNAME 止まりで解決不可 | **10.20.1.4** (PE) | パブリック IP <STORAGE_PUBLIC_IP_2> |
| `conflict.privatelink...` | **10.10.99.99** | **10.20.99.99** | 解決不可 |

読み取れること:

- 同じ FQDN `conflict.privatelink.blob.core.windows.net` が、VNet3 のリンク先次第で
  10.10.99.99 にも 10.20.99.99 にもなる。**同名ゾーンは互いに独立した別世界**であり、
  マージも優先順位付けもされない。
- **3 VNet をフルメッシュでピアリングしていても、リンクしていないゾーンのレコードは一切引けない。**
  ピアリングは L3 の到達性しか与えず、Private DNS のリンクを引き継がない。
- リンク中のゾーンに該当レコードが無い場合、`privatelink.*` ゾーンがその VNet で
  権威になるため **パブリック IP へのフォールバックすら起きない**
  (CNAME `xxx.privatelink.blob.core.windows.net` まで進んで名前解決が終わる)。
  → Storage 自体は生きているのに VM からは到達不能になる。これが実運用で一番刺さる罠。

### 実運用への含意

- 同名ゾーンを RG ごとに乱立させること自体は Azure が許すため、**気付かずに作れてしまう**。
- 破綻するのは「1 つの VNet から複数チームの PE を引きたくなった瞬間」。
  そのときリンクの追加が BadRequest で弾かれ、後付けでの統合が非常に高コストになる。
- したがって `privatelink.*` ゾーンは **サブスクリプション/ランディングゾーン単位で 1 箇所に集約**し、
  各 VNet からそこへリンクする構成が定石。PE 側の RG が分かれていても、
  `private_dns_zone_group` に共有ゾーンの ID を渡せば A レコードは集約先に登録できる。

## 後片付け

```bash
terraform destroy
```

### destroy 時に踏んだ罠: 削除済み VNet リンクのゴースト

`terraform destroy` が Private DNS ゾーンの削除で 409 を返し続けることがある。

```
Error: deleting Private Dns Zone (... Resource Group Name: "dnsmrg-rg2" ...):
performing Delete: unexpected status 409 (409 Conflict) with error: CannotDeleteResource:
Cannot delete resource while nested resources exist. Some existing nested resource IDs include:
'Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net/virtualNetworkLinks/link-vnet3-from-rg2'.
Please delete all nested resources before deleting this resource.
```

ところが、その `link-vnet3-from-rg2` は実際には存在しない。

```
$ az network private-dns link vnet list -g dnsmrg-rg2 -z privatelink.blob.core.windows.net
  -> 空
$ az resource show --ids ".../virtualNetworkLinks/link-vnet3-from-rg2"
  -> ResourceNotFound
```

Azure 内部の子リソース存在チェックだけが古い状態で残っている。リトライしても解消しない。
**存在しないリンクに対して明示的に delete を投げる**とチェックがクリアされ、削除できる。

```bash
az network private-dns link vnet delete -g dnsmrg-rg2 \
  -z privatelink.blob.core.windows.net -n link-vnet3-from-rg2 -y   # エラーにならない (冪等)
az network private-dns zone delete -g dnsmrg-rg2 -n privatelink.blob.core.windows.net -y
terraform destroy   # 残りを片付ける
```

リンクの作成/削除を何度も繰り返した後に起きやすい。本検証では `switch.sh` で
リンク先を rg1 / rg2 / both / none と繰り返し切り替えたのが誘因と思われる。
