# Azure Firewall Premium × japaneast — 実デプロイによるゾーン可用性プローブ

実施日: 2026-08-26 / サブスクリプション: `<SUBSCRIPTION_ID>`（従量課金）
目的: `research.md` §3.5 の通り事前検証 API では判定できないため、**実デプロイで**どのゾーン組み合わせが通るかを確定する。

関連: [research.md](./research.md)

---

## 1. プローブ環境

RG: `rg-fw-zoneprobe`（japaneast）

| リソース | 名前 | 設定 |
| --- | --- | --- |
| VNet | `vnet-fwprobe` | `10.199.0.0/16` / `AzureFirewallSubnet` = `10.199.0.0/26` |
| Public IP | `pip-fwprobe-z123` | Standard / Static / **zones = [1,2,3]（ゾーン冗長）** |
| Firewall Policy | `fwpol-premium` | **tier = Premium** |
| Firewall | `afw-z<zones>` | AZFW_VNet / **tier = Premium** / zones を可変 |

構築コマンド:

```bash
RG=rg-fw-zoneprobe
az group create -n $RG -l japaneast

az network vnet create -g $RG -n vnet-fwprobe -l japaneast \
  --address-prefix 10.199.0.0/16 \
  --subnet-name AzureFirewallSubnet --subnet-prefix 10.199.0.0/26

# known issue 対策: ゾーン指定 FW には「事前作成済みの zone-redundant Public IP」が必要
az network public-ip create -g $RG -n pip-fwprobe-z123 -l japaneast \
  --sku Standard --allocation-method Static --zone 1 2 3

az network firewall policy create -g $RG -n fwpol-premium -l japaneast --sku Premium
```

---

## 2. ⚠ 最初のプローブは無効だった（記録）

1 回目は以下のコマンドで実行し `zones=[1,2,3]` が **成功**したが、**この結果は無効**。

```bash
# NG: IP 構成を指定していない
az network firewall create -g $RG -n afwprobe-123 -l japaneast \
   --sku AZFW_VNet --tier Premium --firewall-policy "$POL" --zones 1 2 3
```

`--vnet-name` / `--public-ip` / `--conf-name` を省略すると **ipConfigurations が空のファイアウォール**が出来る。これは deallocate 状態と同じで、**バックエンド（VMSS）が確保されない＝ゾーン容量ゲートを通過しない**。当然デプロイ課金も始まらない。

> **教訓**: ゾーン容量の検証は、必ず **IP 構成（AzureFirewallSubnet + Public IP）を付けた「割り当て済み」ファイアウォール**で行うこと。

正しいコマンド:

```bash
az network firewall create -g $RG -n afw-z123 -l japaneast \
   --sku AZFW_VNet --tier Premium --firewall-policy "$POL" \
   --vnet-name vnet-fwprobe --public-ip pip-fwprobe-z123 --conf-name ipconfig1 \
   --zones 1 2 3
```

---

## 3. プローブ結果 — Premium SKU / ゾーン組み合わせ

すべて **Premium tier + IP 構成あり（`vnet-fwprobe` / `pip-fwprobe-z123`）** で実施。

| # | zones | 結果 | 所要 | 備考 |
| --- | --- | --- | --- | --- |
| 1 | `1 2 3` | ❌ FAILED | 約 3 秒 | `AzureFirewallUnsupportedAvailabilityZone` |
| 2 | `2 3` | ❌ FAILED | 約 3 秒 | 同上 |
| 3 | `1 3` | ❌ FAILED | 約 3 秒 | 同上 |
| 4 | **`1 2`** | ✅ **SUCCESS** | **7分54秒** | `provisioningState=Succeeded` / privateIP `10.199.0.4` |

エラー全文（#1〜#3 共通）:

```
ERROR: (AzureFirewallUnsupportedAvailabilityZone) Deployment of Premium SKU firewall
with the specified availability zones is currently not supported in 'japaneast'.
You may retry different availability zones settings or a different SKU / region.
Code: AzureFirewallUnsupportedAvailabilityZone
```

成功時のリソース状態:

```json
{ "state": "Succeeded", "tier": "Premium", "zones": ["1","2"], "ipcfg": 1, "privIp": "10.199.0.4" }
```

### 3.1 切り分け結論

**ゾーン 3 を含む組み合わせのみが全滅し、含まない `1,2` は成功した。**

→ **論理ゾーン 3 が Premium SKU の容量ゲートに掛かっている。** 本サブスクリプションのマッピング（`research.md` §3.2）では:

| 論理ゾーン | 物理ゾーン | Premium 可否 |
| --- | --- | --- |
| 1 | `japaneast-az2` | ✅ 利用可 |
| 2 | `japaneast-az3` | ✅ 利用可 |
| **3** | **`japaneast-az1`** | ❌ **容量不足** |

> **注意**: 塞がっているのは**物理ゾーン `japaneast-az1`**。他サブスクリプションでは論理ゾーン番号が変わるため、
> 「ゾーン 3 を避ける」ではなく **「物理 `japaneast-az1` にマップされる論理ゾーンを避ける」**と表現して引き継ぐこと。

### 3.2 失敗は 3 秒・無課金

容量ゲートは PUT のごく初期に RP が判定するため、**失敗は約 3 秒で返る（プロビジョニングに入らない＝課金なし）**。
一方 `research.md` §3.5 の通り `az deployment group validate` は素通りするので、**この 3 秒の実 PUT が事実上の唯一の検査手段**。

---

### 3.3 追加検証: ゾーン 3 単体（Premium）

```bash
az network firewall create -g $RG -n afw-z3only -l japaneast \
  --sku AZFW_VNet --tier Premium --firewall-policy "$POL" \
  --vnet-name vnet-fwprobe --public-ip pip-fwprobe-z123 --conf-name ipconfig1 --zones 3
```

→ ❌ **FAILED**（同じ `AzureFirewallUnsupportedAvailabilityZone`、約 3 秒）。
論理ゾーン 3 が単体でも使えないことを直接確認。§3.1 の切り分けが確定。

---

## 4. プローブ結果 — Standard で 3 ゾーン作成 → Premium へ SKU 変更

`research.md` §4.2 の回避策（容量ゲートが SKU 単位である前提）を検証。

```bash
az network firewall create -g $RG -n afw-skuchg -l japaneast \
   --sku AZFW_VNet --tier Standard --firewall-policy "$POL_S" \
   --vnet-name vnet-fwprobe --public-ip pip-fwprobe-z123 --conf-name ipconfig1 \
   --zones 1 2 3
```

結果: ❌ **FAILED**（約 4 秒）

```
ERROR: (AzureFirewallUnsupportedAvailabilityZone) Deployment of Standard SKU firewall
with the specified availability zones is currently not supported in 'japaneast'.
```

→ **Standard SKU でも 3 ゾーンは作成できない。SKU 変更による 3 ゾーン確保という迂回路は成立しない。**
（Premium 昇格の STEP2 は STEP1 が通らなかったため未実施）

### 4.1 判明した重要な事実

**今回の japaneast の容量制約は SKU 依存ではなく、ゾーン依存。**
Learn の known issues 表にある `Basic/Standard/Premium` 全 SKU 影響のパターン（South Central US・West US 2・Spain Central と同型）に該当する。
`research.md` §4.2 の「Standard なら通るかもしれない」という仮説は**本件では否定された**。

> エラーメッセージが `Premium SKU firewall` と名指しするため SKU 固有の問題に見えるが、これは**単に要求した tier 名を埋め込んでいるだけ**。Standard で試せば `Standard SKU firewall` と出る。**メッセージの SKU 名に惑わされないこと。**

---

## 5. 最終結論

| 構成 | 可否 |
| --- | --- |
| Premium / zones `1,2,3` | ❌ 不可 |
| Premium / zones `1,3` `2,3` `3` | ❌ 不可 |
| **Premium / zones `1,2`** | ✅ **可（推奨構成）** |
| Standard / zones `1,2,3` | ❌ 不可 |

**推奨: Premium SKU × japaneast × `--zones 1 2` の 2 ゾーン構成。**

- ゾーン冗長要件は満たす（Azure Firewall SLA は **2 ゾーン以上で 99.99%**。3 ゾーンにしても数値は変わらない）
- Premium / japaneast の必須要件も維持
- 3 ゾーンが監査・社内標準などで絶対要件の場合は、**物理 `japaneast-az1` の容量開放を待つしかない**（サポート起票 → `research.md` §4.3）

### 実デプロイ用コマンド

```bash
# 前提: zone-redundant な Public IP を先に作成しておくこと (FW は 1,2 でも PIP は 1,2,3)
az network public-ip create -g <RG> -n <pip> -l japaneast \
  --sku Standard --allocation-method Static --zone 1 2 3

az network firewall create -g <RG> -n <fw> -l japaneast \
  --sku AZFW_VNet --tier Premium --firewall-policy <policy-id> \
  --vnet-name <vnet> --public-ip <pip> --conf-name ipconfig1 \
  --zones 1 2
```

> **Public IP は FW のゾーンに揃えず、zone-redundant(`--zone 1 2 3`)で作ること。**
> 今回のプローブは zone-redundant PIP + `--zones 1 2` の FW で成功している。Public IP の `zones` も作成後は変更不可なので、
> `1 2` で作ってしまうと将来 3 ゾーン化する際に **PIP の作り直し（＝IP アドレス変更）** が必要になる。1,2,3 で作っておけば
> FW 側のゾーン追加だけで済む（§6 参照）。

### 再確認の手順（容量が開放されたかの定期チェック）

失敗は約 3 秒・無課金で返るので、3 ゾーンが必要なら以下を定期実行して開放を検知できる。

```bash
az network firewall create -g $RG -n zonecheck -l japaneast \
  --sku AZFW_VNet --tier Premium --firewall-policy "$POL" \
  --vnet-name $VNET --public-ip $PIP --conf-name ipconfig1 --zones 1 2 3
# 成功したら即 delete（成功時は 8 分ほどかかり、Premium は 286.8 円/時の課金が始まる）
```

---

## 6. ゾーンを `1,2` → `1,2,3` に変更する場合（将来、物理 az1 の容量が開放されたとき）

### 6.1 Azure（ARM / プラットフォーム）としては「リソース再作成は不要」

**同一リソース（同じ resource ID・名前・ルール・ポリシー・タグ）のまま変更できる。** ただし単純な更新では不可。

- **そのまま PUT/PATCH でゾーンだけ変えるのは拒否される**:
  ```
  Code: AzureFirewallAvailabilityZonesCannotBeModified
  Azure Firewall /subscriptions/.../afw-xxx has an existing availability zone constraint and
  the request has availability zone constraint 1, 2, 3, which do not match
  ```
  → **ARM テンプレート / Bicep / az CLI だけではゾーン変更できない。**
- **正規の手順は PowerShell の deallocate → allocate（`research.md` §5.2）**:
  ```powershell
  # STEP1: 停止 (実測 約 6分30秒)
  $azfw = Get-AzFirewall -Name "FW" -ResourceGroupName "RG"
  $azfw.Deallocate(); Set-AzFirewall -AzureFirewall $azfw
  # STEP2: ゾーンを変えて起動 (実測 約 6分30秒)
  $azfw = Get-AzFirewall -Name "FW" -ResourceGroupName "RG"
  $vnet = Get-AzVirtualNetwork -ResourceGroupName "RG" -Name "VNet"
  $pip  = Get-AzPublicIpAddress -ResourceGroupName "RG" -Name "azfwpublicip"
  $azfw.Allocate($vnet, $pip)
  $azfw.Zones = 1, 2, 3
  Set-AzFirewall -AzureFirewall $azfw
  ```
- **ダウンタイム 13〜15 分程度**。az CLI に相当コマンドはない（PowerShell 専用）。
- 前提条件（FAQ）: VNet 型であること（Secured Virtual Hub は不可）／リージョンが AZ 対応／**アタッチされている全 Public IP が同じゾーン構成であること**。

### 6.2 Terraform では「再作成（destroy → create）」になる

`azurerm_firewall` の `zones` は **ForceNew**:

> "Specifies a list of Availability Zones in which this Azure Firewall should be located.
> **Changing this forces a new Azure Firewall to be created.**"

- `zones` を `["1","2"]` → `["1","2","3"]` に書き換えると **plan が replace になる**。
- 参考: `sku_tier` は ForceNew **ではない**（Standard↔Premium は in-place 更新可能）。`sku_name` / `location` / `ip_configuration.subnet_id` は ForceNew。
- Terraform 管理下でリソースを壊さずゾーン変更したい場合は、**PowerShell で §7.1 を実施 →`zones` をコードに反映 → `terraform plan` が差分なしになることを確認**（または `terraform apply -refresh-only`）という手順を採る。

### 6.3 本件特有のリスク

| リスク | 内容 |
| --- | --- |
| **停止したまま起動不能** | 物理 `japaneast-az1` が塞がったまま deallocate → `Zones = 1,2,3` で allocate すると **STEP2 が失敗し、FW は停止状態のまま残る**。`Zones = 1,2` で allocate し直せば復帰できるはずだが、known issues が警告する「容量制約リージョンで停止すると起動できない」状況そのもの。**先に §5 末尾の 3 秒プローブで 1,2,3 が通ることを別リソースで確認してから実施すること。** |
| **プライベート IP の変化** | deallocate/allocate 後は AzureFirewallSubnet から動的に再払い出しされ、IP が変わりうる。**UDR の next hop を再設定する必要がある**（`research.md` §5.4） |
| **Public IP のゾーン** | PIP の `zones` は作成後変更不可。`1 2` で作っていると 3 ゾーン化時に PIP 作り直し＝**パブリック IP アドレスが変わる**。→ 最初から `--zone 1 2 3` で作っておくこと |

### 6.4 まとめ

| 観点 | 再作成になるか |
| --- | --- |
| Azure リソースとして | ❌ ならない（deallocate/allocate で同一リソースを更新。ダウンタイム 13〜15 分） |
| ARM / Bicep / az CLI 単体で | ⚠ 変更自体できない（`AzureFirewallAvailabilityZonesCannotBeModified`） |
| **Terraform (`azurerm_firewall`)** | ✅ **なる（`zones` は ForceNew → destroy/create）** |
| Public IP を `1,2` で作っていた場合 | ✅ PIP は作り直し（IP アドレスが変わる）→ **最初から 1,2,3 で作る** |

---

## 7. 後片付け

```bash
az group delete -n rg-fw-zoneprobe --yes --no-wait
```

実施済み。プローブで発生した課金は Premium Deployment 約 8 分ぶん（**約 40 円**）＋ Public IP 数十分ぶん。
失敗した試行（`1,2,3` / `2,3` / `1,3` / `3` / Standard `1,2,3`）はプロビジョニングに入っていないため無課金。
