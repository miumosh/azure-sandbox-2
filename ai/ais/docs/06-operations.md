# 運用 / トラブルシュート

## 1. 疎通確認

```bash
./verify.sh              # 全アカウント
./verify.sh openai       # 絞る (speech / aiservices / openai)
```

`verify.sh` は VNet 内 (probe VM) と VNet 外 (実行端末) を並べて表示する。
VNet 内の実行は `az vm run-command` 経由なので **SSH も Bastion も不要**。
認証は VM のマネージド ID (Entra ID) で、キーをスクリプトに埋め込まない。

### 判定表

| 観測 | 意味 |
|---|---|
| VNet 内の名前解決が `10.60.10.x` | **OK。** Private 経路が成立 |
| VNet 内の名前解決が公開 IP | ゾーン不足 / VNet リンク漏れ / ホスト名の粒度違い |
| データ面 API が **403** + `Public access is disabled` | **ネットワーク遮断** (閉域化できている) |
| データ面 API が **401** + `audience is incorrect` | トークンのオーディエンス違い。ネットワークは無罪 |
| データ面 API が 401 / 404 (その他) | ネットワークは通ってアプリ層まで到達 |
| **ルートパス `/` が 200** | **何も意味しない。** 閉域でも 200 を返す |

---

## 2. よくあるエラー

| 症状 | 原因 / 対処 |
|---|---|
| ルートパス `/` が 200 で返るので閉域化できていないように見える | `/` は public 無効でも 200。**データ面 API で判定すること** |
| `*.privatelink.*` を curl すると `HTTP 000` | 内部名は TLS 証明書の SAN に無い。`privatelink` を抜いた公開名を使う |
| データ面が 401 `audience is incorrect` | Foundry プロジェクト API は `https://ai.azure.com` のトークンが必要 |
| `ServiceModelDeprecating` でモデルデプロイが 400 | モデルが廃止予定。下記コマンドで GA の版に差し替える |
| `InsufficientQuota` でモデルデプロイが失敗 | `enable_model_deployment = false` にするか `locals.tf` の `sku_capacity` を下げる |
| PE 作成が `AccountProvisioningStateInvalid` | アカウントが `Accepted` 状態のときの一過性エラー。`terraform apply` を再実行 |
| role_assignment が `Missing required argument: principal_id` | VM に後からマネージド ID を足したとき。`terraform apply -target=azurerm_linux_virtual_machine.jumpbox` を先に流す |
| `could not find role 'Azure AI User'` | **そのロールは存在しない**。`Azure AI Developer` / `Azure AI Administrator` を使う |
| plan が `delete, create` になる | `replace_paths` を確認する。`project_management_enabled` / `custom_subdomain_name` は ForceNew |
| Storage のコンテナが作れない | 閉域化すると terraform 実行端末からデータ面に到達できない。azapi (ARM) 経由で作る |
| Speech SDK が 401 | カスタムサブドメイン有効化で `FromSubscription` が使えない → [05-speech.md](05-speech.md) |

### 利用可能なモデルを調べる

```bash
az cognitiveservices account list-models -g rg-aissbx -n oai-aissbx-xxxxx \
  --query "[?lifecycleStatus=='GenerallyAvailable' && contains(name,'gpt')].{n:name,v:version,s:join(',',skus[].name)}" \
  -o table
```

### 置換の理由を確認する

```bash
terraform plan -out=tf.plan && terraform show -json tf.plan | python3 -c "
import json,sys
for r in json.load(sys.stdin)['resource_changes']:
    if 'delete' in r['change']['actions']:
        print(r['address'], r['change'].get('replace_paths'))
"
```

---

## 3. 状態確認

```bash
RG=rg-aissbx

# 公開範囲を総ざらい (どのリソースが閉じているか)
for id in $(az resource list -g $RG --query "[].id" -o tsv); do
  pna=$(az resource show --ids "$id" --query "properties.publicNetworkAccess" -o tsv 2>/dev/null)
  [ -n "$pna" ] && echo "$pna  $(basename $id)"
done

# PE が公開するホスト名と IP (customDnsConfigs は空なので NIC を見る)
for pe in $(az network private-endpoint list -g $RG --query "[].name" -o tsv); do
  nic=$(az network private-endpoint show -g $RG -n "$pe" --query "networkInterfaces[0].id" -o tsv)
  echo "-- $pe"
  az network nic show --ids "$nic" \
    --query "ipConfigurations[].{ip:privateIPAddress, fqdns:privateLinkConnectionProperties.fqdns}" -o tsv
done

# Private DNS Zone に登録された A レコード
for z in $(az network private-dns zone list -g $RG --query "[].name" -o tsv); do
  echo "-- $z"
  az network private-dns record-set a list -g $RG -z "$z" \
    --query "[].{n:name, ip:aRecords[0].ipv4Address}" -o tsv
done

# ネットワーク設定
az cognitiveservices account show -g $RG -n ais-aissbx-xxxxx \
  --query "properties.{pna:publicNetworkAccess, acls:networkAcls, proj:allowProjectManagement}"

# v2 プロジェクト
az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/ais-aissbx-xxxxx/projects?api-version=2025-06-01" \
  --query "value[].{name:name, isDefault:properties.isDefault}" -o table
```

---

## 4. モードを切り替えて A/B する

閉域化の影響を比較したいとき。

```bash
# ポータルが確実に使えるモードに戻す (public 有効 + defaultAction = Allow)
sed -i 's/ai_network_mode = "private"/ai_network_mode = "portal"/' terraform.tfvars
terraform apply

# 許可 IP のみ (API は通るがポータルは使えない)
sed -i 's/ai_network_mode = "portal"/ai_network_mode = "restricted"/' terraform.tfvars
echo 'allowed_client_ips = ["'"$(curl -s https://ifconfig.me/ip)"'"]' >> terraform.tfvars
terraform apply
```

| モード | 設定 | AI Foundry ポータル | API (許可 IP から) | PE 経由 |
|---|---|---|---|---|
| `private` (既定) | public 無効 | VNet 内のみ | 不可 | 可 |
| `portal` | public 有効 + `Allow` | **使える** | 可 | 可 |
| `restricted` | public 有効 + `Deny` + 許可 IP | **使えない** (`ai/ai_foundry` で実測) | 可 | 可 |

**どのモードでも PE 経由の経路は維持される。**

---

## 5. Bastion + Windows VM (ポータル手動確認)

```bash
cat >> terraform.tfvars <<'EOT'
enable_bastion                 = true
windows_jumpbox_admin_password = "<12文字以上のパスワード>"
EOT
terraform apply
```

1. Azure ポータル → `rg-aissbx` → VM `vm-aissbx-win`
2. **接続 → Bastion** → ユーザー名 `azureuser` / 上記パスワード
3. VM 内の Edge で `https://ai.azure.com`

確認手順の詳細は [03-portal-and-gui.md](03-portal-and-gui.md)。

**確認が終わったら必ず落とす** (Bastion は起動中つねに時間課金):

```bash
sed -i 's/enable_bastion                 = true/enable_bastion = false/' terraform.tfvars
terraform apply
```

---

## 6. 課金対象

`ai_network_mode` に関わらず常時課金されるもの:

| リソース | 個数 | 備考 |
|---|---|---|
| Private Endpoint | 7 | 時間課金 + データ処理量 |
| Linux VM (`Standard_B2s`) | 1 | `enable_jumpbox = false` で止まる |
| Public IP (Standard) | 1〜3 | VM / Bastion 用 |
| **Azure Bastion (Basic)** | 0 or 1 | **`enable_bastion = true` のときのみ。単価が高い** |
| Storage / Key Vault | 各 1 | ほぼ無視できる |
| Cognitive アカウント | 3 | S0 は従量課金。アイドル時のコストなし |
| モデルデプロイ (`GlobalStandard`) | 2 | 従量課金。アイドル時のコストなし |
| Container Apps 環境 (injection) | 0 or 1 | `enable_vnet_injection = true` のとき。アイドル時は最小構成 |

検証が終わったら destroy するか、少なくとも
`enable_jumpbox = false` / `enable_bastion = false` にすること。

---

## 7. destroy

```bash
terraform destroy
```

### ★ virtual network injection を使っていると destroy が 409 で止まる (実測)

```
Error: deleting Account (...aisinj-aissbx-xxxxx): performing AccountsDelete:
unexpected status 409 (409 Conflict) with error: RequestConflict:
Cannot modify resource ... because the resource entity provisioning state is not
terminal. Please wait for the provisioning state to become terminal and then retry.
```

| 項目 | 内容 |
|---|---|
| 対象 | `network_injection` を持つアカウント |
| 原因 | 委任サブネットの Container Apps 環境のテアダウンに時間がかかり、削除要求時点で `provisioningState` が非終端 (`Deleting`) |
| 実測の所要時間 | **13 分経過時点でまだ `Deleting`** |
| 対処 | 終端状態になるまで待ってから `terraform destroy` を再実行する |

**作成に 5 分 35 秒かかったのと対になる挙動。injection 付きアカウントは作成も削除も遅い。**

```bash
# 終端状態 (または消滅) を待ってから再実行する
SUB=<subscription-id>; RG=rg-aissbx; ACC=aisinj-<suffix>
until ! az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACC?api-version=2025-06-01" \
  >/dev/null 2>&1; do sleep 30; done
terraform destroy
```

> destroy は途中まで進むため、**RG / VNet / サブネット / 該当アカウントだけが
> 残った状態**で止まる。他のリソース (Storage / Key Vault / Hub / PE / VM) は
> 先に消えている。

### ★ 409 で落ちた後の再実行では purge が走らない (実測)

**これが一番見落としやすい。**

`providers.tf` の `purge_soft_delete_on_destroy = true` は
**Terraform がそのリソースを削除したときにだけ**働く。
初回の destroy が 409 で落ち、その間に Azure 側で削除が完了してしまうと、
再実行時には Terraform から見て「もう無い」ので state から外すだけになり、
**purge が実行されない。**

実測: destroy 完了後も論理削除の残骸が残っていた。

```
$ az cognitiveservices account list-deleted --query "[?contains(name,'aissbx')].name" -o tsv
aisinj-aissbx-xxxxx        # ← 残っている
```

| 症状 | `terraform state list` は空、RG も消えているのに論理削除の残骸が残る |
|---|---|
| 原因 | 初回 destroy が 409 で中断 → Azure 側で削除完了 → 再実行時 Terraform は state から外すだけ |
| 影響 | **名前がグローバルに予約されたままになる。**同名で作り直せない |
| 対処 | 手動で purge する |

```bash
# 残骸の確認
az cognitiveservices account list-deleted \
  --query "[?contains(name,'aissbx')].{name:name, location:location}" -o table

# purge (location は上の出力から取る)
az cognitiveservices account purge -g rg-aissbx -n aisinj-<suffix> -l japaneast
```

> **destroy が一度でもエラーで止まったら、完了後に必ず残骸を確認すること。**
> Key Vault も同様 (`az keyvault list-deleted` / `az keyvault purge -n <name>`)。

### 削除順序 (virtual network injection を使っている場合)

`network_injection` を使うとサブネットに `legionservicelink` という
serviceAssociationLink が張られ、**これがある限りサブネットを削除できない。**

| 順序 | 操作 | 理由 |
|---|---|---|
| 1 | Foundry アカウントを削除 | — |
| 2 | **論理削除されたアカウントを purge** | purge しないと SAL が残る |
| 3 | VNet / サブネットを削除 | — |

```
Subnet requires any of the following delegation(s) [Microsoft.App/environments]
to reference service association link .../serviceAssociationLinks/legionservicelink.
```

このエラーが出たら、Azure ポータルの Foundry リソースページ →
**「削除されたリソースの管理」**から purge する。

本構成は `providers.tf` で `purge_soft_delete_on_destroy = true` を設定済みのため、
`terraform destroy` なら自動で purge される。

### 入れ子 v2 プロジェクトで 409 になる場合

`allowProjectManagement = true` により Azure が入れ子プロジェクトを
自動生成していると、Terraform 管理外のため親アカウントの削除が拒否される。

```
Error: deleting Account ... 409 (409 Conflict) CannotDeleteResource:
Cannot delete resource while nested resources exist.
```

> 本構成では v2 プロジェクトを `azurerm_cognitive_account_project` で
> **明示的に管理している**ため、通常はこの問題は起きない。
> 自動生成されたものが残っている場合のみ以下を実行する。

```bash
SUB=<subscription-id>; RG=rg-aissbx; ACC=ais-aissbx-<suffix>
BASE="https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACC"

for p in $(az rest --method get --url "$BASE/projects?api-version=2025-06-01" --query "value[].name" -o tsv); do
  az rest --method delete --url "$BASE/projects/${p##*/}?api-version=2025-06-01"
done

terraform destroy
```

### destroy 後の確認

論理削除の残骸が課金や名前衝突の原因になる。**destroy が成功しても必ず確認する。**

| 確認項目 | コマンド | 期待値 |
|---|---|---|
| Terraform の state | `terraform state list` | **空** |
| リソースグループ | `az group exists -n rg-aissbx` | **false** |
| サブスク全体の取りこぼし | `az resource list --query "[?contains(name,'aissbx')]" -o tsv` | **空** |
| Cognitive の論理削除 | `az cognitiveservices account list-deleted -o table` | **該当なし** |
| Key Vault の論理削除 | `az keyvault list-deleted -o table` | **該当なし** |

```bash
cd ai/ais
terraform state list                  # 空であること
az group exists -n rg-aissbx          # false であること
az resource list --query "[?contains(name,'aissbx')].{name:name,type:type}" -o tsv
az cognitiveservices account list-deleted --query "[?contains(name,'aissbx')].name" -o tsv
az keyvault list-deleted --query "[?contains(name,'aissbx')].name" -o tsv
```

本検証の最終結果: state 0 件 / RG `false` / サブスク全体に残骸なし /
Cognitive の残骸 1 件 (**手動 purge が必要だった。上記「409 で落ちた後」を参照**) /
Key Vault の残骸なし。

Key Vault と Cognitive アカウントは `providers.tf` で
`purge_soft_delete_on_destroy = true` を設定済みのため自動パージされる。
残っていた場合:

```bash
az keyvault purge -n kv-aissbx-<suffix>
az cognitiveservices account purge -g rg-aissbx -n <name> -l japaneast
```
