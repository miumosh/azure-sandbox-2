# VM の Public IP と Azure Firewall を併用したアウトバウンド制御

## 要件

| # | 要件 | 実現方法 |
|---|------|----------|
| 1 | 外部 → VM へのアクセスは Public IP | NIC に インスタンスレベル Public IP (ILPIP) |
| 2 | Public IP で受けた通信は Public IP から返す | 送信元クライアント CIDR 宛の UDR (next hop = Internet) |
| 3 | VM → 宛先A / 宛先B は Public IP から直接出る | 宛先 CIDR / Service Tag の UDR (next hop = Internet) |
| 4 | それ以外は Azure Firewall 経由 | `0.0.0.0/0` → next hop = VirtualAppliance (Firewall の内部 IP) |

## なぜ「戻り」にもルートが要るのか

Azure のルートテーブルは **宛先 (destination) でしか分岐できない**。
インバウンド自体は Public IP に直接届くのでルートの影響を受けないが、その
**応答パケット**は「クライアントの Public IP 宛のアウトバウンド」として
評価される。`0.0.0.0/0 → Firewall` だけを置くと応答が Firewall へ吸われ、
Firewall には該当セッションが無いので破棄される（非対称ルーティング）。

そのため `var.inbound_clients` の CIDR を **next hop = Internet** の UDR として
入れ、行きと戻りを同じ Public IP に揃えている。

```
[client 203.0.113.10]
      │ ① 行き: dst = VM Public IP → ILPIP に直接着弾（ルート評価なし）
      ▼
  [ VM 10.0.1.4 / ILPIP ]
      │ ② 戻り: dst = 203.0.113.10 → UDR "return-office" (Internet) → ILPIP から返る
      │ ③ 宛先A/B: dst = 198.51.100.0/24 → UDR "direct-dest_a" (Internet) → ILPIP から出る
      │ ④ その他: dst = 0.0.0.0/0 → UDR (VirtualAppliance) → Firewall で SNAT → Firewall の PIP
      ▼
```

ルート選択は **最長プレフィックス一致 → 同一プレフィックスなら UDR > BGP > システム**。
個別ルート（`/32`〜`/24` や Service Tag）は必ず `0.0.0.0/0` より優先される。

## 検証結果

2026-09-09 に japaneast / Azure Firewall Standard SKU で実機デプロイして確認した。

### 検証環境

| 項目 | 値 |
|------|-----|
| リージョン | japaneast |
| リソースグループ | `rg-fwpip-xxxxxx` |
| Firewall SKU | Standard (`AZFW_VNet`) |
| VM | Ubuntu 24.04 LTS / Standard_B2s / nginx |
| VM Public IP (ILPIP) | `<VM_PUBLIC_IP>` |
| Firewall Public IP | `<FW_PUBLIC_IP>` |
| Firewall Private IP | `10.0.0.4` |
| クライアント (検証元 PC) | `<CLIENT_GLOBAL_IP>` |

`terraform.tfvars`:

```hcl
inbound_clients = {
  home_pc = "<CLIENT_GLOBAL_IP>/32"
}

# Cloudflare のエニーキャスト DNS。IP が固定で、
# https://<ip>/cdn-cgi/trace が送信元 IP をエコーバックするので検証に使える
direct_destinations = {
  dest_a = "1.1.1.1/32"
  dest_b = "1.0.0.1/32"
}
```

### 1. 実効ルートの確認

```bash
az network nic show-effective-route-table -g rg-fwpip-xxxxxx -n nic-vm-fwpip -o table
```

```
Source    State    Address Prefix     Next Hop Type     Next Hop IP
--------  -------  -----------------  ----------------  -------------
Default   Active   10.0.0.0/16        VnetLocal
User      Active   <CLIENT_GLOBAL_IP>/32  Internet            <- return-home_pc
User      Active   1.1.1.1/32         Internet            <- direct-dest_a
User      Active   1.0.0.1/32         Internet            <- direct-dest_b
Default   Invalid  0.0.0.0/0          Internet            <- UDR に上書きされ無効化
User      Active   0.0.0.0/0          VirtualAppliance  10.0.0.4
```

既定の `0.0.0.0/0 → Internet` が `Invalid` に落ち、UDR の `VirtualAppliance` が
`Active` になっている。個別の `/32` ルートは最長プレフィックス一致で
`0.0.0.0/0` より優先されるため、両方が同時に `Active` で共存する。

### 2. アウトバウンドの経路分岐

```bash
az vm run-command invoke -g rg-fwpip-xxxxxx -n vm-fwpip \
  --command-id RunShellScript --scripts '
    curl -s https://1.1.1.1/cdn-cgi/trace | grep ^ip=
    curl -s https://1.0.0.1/cdn-cgi/trace | grep ^ip=
    curl -s https://ifconfig.me
    curl -s -o /dev/null -w "%{http_code}" https://example.com
  '
```

```
### dest_a 1.1.1.1 (UDR direct)
ip=<VM_PUBLIC_IP>
loc=JP
### dest_b 1.0.0.1 (UDR direct)
ip=<VM_PUBLIC_IP>
### via firewall (ifconfig.me, allowed FQDN)
<FW_PUBLIC_IP>
### via firewall (example.com, NOT allowed)
000
```

| # | テスト | 期待 | 結果 |
|---|--------|------|------|
| 1 | VM → `https://1.1.1.1/cdn-cgi/trace` (宛先A) | 送信元 = VM PIP | **`ip=<VM_PUBLIC_IP>`** ✅ |
| 2 | VM → `https://1.0.0.1/cdn-cgi/trace` (宛先B) | 送信元 = VM PIP | **`ip=<VM_PUBLIC_IP>`** ✅ |
| 3 | VM → `https://ifconfig.me` (許可 FQDN) | 送信元 = Firewall PIP | **`<FW_PUBLIC_IP>`** ✅ |
| 4 | VM → `https://example.com` (未許可 FQDN) | Firewall で遮断 | **`000` (接続不可)** ✅ |

**宛先A/B は Firewall のアプリケーションルールに載せていない。** それでも 1/2 が
成功したということは、Firewall を通っていない = UDR で迂回できている。もし
Firewall 経由なら 4 と同じく遮断されるはずである。逆に 3 が Firewall の Public IP
で返ることで、既定経路が確かに Firewall を通っていることも同時に確認できる。

### 3. インバウンドと戻り経路

クライアント PC から VM の Public IP へ直接アクセス:

```bash
curl -s -o /dev/null -w "http_code=%{http_code} remote=%{remote_ip}\n" http://<VM_PUBLIC_IP>/
```

```
http_code=200 remote=<VM_PUBLIC_IP>
```

### 4. 戻りルートが必須であることの実証 (ネガティブテスト)

`return-home_pc` ルートだけを削除して同じインバウンドを試す:

```bash
az network route-table route delete -g rg-fwpip-xxxxxx \
  --route-table-name rt-snet-vm -n return-home_pc
```

```
try1: http_code=000
try2: http_code=000
try3: http_code=000
try4: http_code=000
try5: http_code=000
```

行きのパケットは Public IP に直接着弾するので変わらず届くが、応答が
`0.0.0.0/0 → Firewall` に乗って Firewall へ吸われ、Firewall 側に該当セッションが
無いため破棄される（非対称ルーティング）。NSG も UDR 以外の設定も一切変えて
いないので、**インバウンドの成否を決めているのは戻りルートだけ**だと分かる。

`terraform apply` でルートを戻すと即座に復帰する:

```
restored try1: http_code=200
restored try2: http_code=200
restored try3: http_code=200
```

### 5. デプロイ時に判明した Azure 側の制約

初回 apply は以下で失敗した:

```
Error: creating Route (... Route Name: "azure-platform"): performing CreateOrUpdate:
unexpected status 400 (400 Bad Request) with error:
AddressPrefixInRestrictedAddressSpace: AddressPrefix 168.63.129.16/32 for route
azure-platform is not allowed because its in restricted address space.
```

強制トンネル構成では `168.63.129.16/32` を `Internet` に逃がす、という記述を
見かけるが、**Azure は現在この UDR 自体を受け付けない**。制限アドレス空間として
プラットフォーム側で処理され UDR の影響を受けないため、`0.0.0.0/0` を Firewall に
向けても素通しされる。当該ルートを削除して再 apply し、VM Agent (run-command)・
DNS・cloud-init の apt がいずれも正常動作することを確認済み。

### まとめ

| 要件 | 判定 |
|------|------|
| 外部 → VM へのアクセスは Public IP | ✅ 200 応答 |
| Public IP で受けた通信は Public IP から返す | ✅ 戻りルート有無で挙動が反転することを実証 |
| VM → 宛先A / 宛先B は Public IP から直接出る | ✅ 送信元 = `<VM_PUBLIC_IP>` |
| それ以外は Azure Firewall 経由 | ✅ 送信元 = `<FW_PUBLIC_IP>`、未許可 FQDN は遮断 |

## 注意点 / 制約

- **不特定多数からの着信には使えない。** 戻りルートを CIDR で列挙する必要が
  あるため、クライアントが特定できない公開サービスでは成立しない。その場合は
  - Azure Firewall の DNAT で受ける（送信元は Firewall の PIP、戻りも Firewall 経由で対称）
  - Standard Load Balancer + Firewall の組み合わせ
  のどちらかに切り替える。
- **宛先A/B は IP で特定できる必要がある。** UDR は FQDN を扱えない。IP が
  流動する相手なら Service Tag（`address_prefix` に指定可能）を使うか、
  Firewall のアプリケーションルールで FQDN 許可して Firewall 経由に倒す。
- **`address_prefix` は配列にできない。** ARM の `routes.properties.addressPrefix`
  が単一文字列のため、1 ルート = 1 プレフィックス（ルートテーブルあたり上限 400）。
  数を減らしたい場合は集約 CIDR か Service Tag を使う。ただし集約すると、その
  範囲宛の**アウトバウンドもまとめて** Firewall を迂回する点に注意。
- **迂回した通信は Firewall のログに残らない。** 宛先A/B とインバウンドは
  Firewall を通らないので、監査は NSG フローログ側で行う。
- **ルートテーブルは VM サブネットにのみ関連付ける。** `AzureFirewallSubnet`
  に付けると Firewall 自身の戻り経路がループする。
- **`0.0.0.0/0` を `inbound_clients` / `direct_destinations` に入れない。**
  Firewall 経由がすべて無効化されるため variable の validation で弾いている。
- Basic SKU を選ぶと `AzureFirewallManagementSubnet` と管理用 Public IP が
  追加で必要になる（コード側で自動的に作り分ける）。
- **`168.63.129.16/32` の UDR は作れない。** DHCP / DNS / VM Agent 用の Azure 仮想
  パブリック IP で、ルートを作ろうとすると
  `AddressPrefixInRestrictedAddressSpace` で 400 が返る。制限アドレス空間として
  プラットフォーム側で処理され UDR の影響を受けないため、`0.0.0.0/0` を Firewall
  に向けても素通しされる（明示ルートは不要かつ不可）。

## ファイル構成

| ファイル | 内容 |
|----------|------|
| `providers.tf` | provider / version 固定 |
| `variables.tf` | 環境依存値（クライアント CIDR、宛先A/B など） |
| `locals.tf` | ネットワーク設計値、ルート定義、Firewall 許可 FQDN |
| `network.tf` | VNet / Subnet / NSG |
| `firewall.tf` | Azure Firewall + ポリシー（OS Update 等の許可） |
| `route.tf` | **本構成の中核**。UDR による経路の作り分け |
| `vm.tf` | ILPIP 付き VM |
| `outputs.tf` | 検証に使う出力 |
