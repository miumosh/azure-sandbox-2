# AKS ノードプールのゾーン変更 ([1,2] / null -> [1,2,3]) 検証

| 対象 | 変更前 | 変更後 |
|------|--------|--------|
| `azurerm_kubernetes_cluster.default_node_pool.zones` | `["1","2"]` | `["1","2","3"]` |
| `azurerm_kubernetes_cluster_node_pool.zones` | `null` (非ゾーン) | `["1","2","3"]` |

このように変更したとき、次の 3 点を実機で確認する。

1. Terraform の plan は replace と in-place のどちらになるか (別環境では両方 in-place だった)
2. apply で**実際に**何が起きるか (ノードプール・ノード・VMSS が作り直されるか)
3. ZRS ディスク (Premium_ZRS) の PVC を使う Pod への影響 (データ保持・停止時間・再スケジュール)

## 事前調査 (provider ソース, azurerm v4.80.0)

- どちらの `zones` も **ForceNew ではない**。そのため plan では `~ update in-place` と表示される。
- 一方で `zones` は「cycle (rotation) 対象のプロパティ」に入っており、apply 時に次の処理が走る。
  1. 新しい zones を持つ一時ノードプール (`temporary_name_for_rotation`) を作る
  2. **元のノードプールを削除する**
  3. 同じ名前のノードプールを新しい zones で作り直す
  4. 一時ノードプールを削除する
  - 該当箇所: `kubernetes_cluster_node_pool_resource.go` の `cycleNodePoolProperties`、
    `kubernetes_cluster_resource.go` の `default_node_pool.0.zones`
- `temporary_name_for_rotation` が未設定だと、plan は通るのに apply が
  `` `temporary_name_for_rotation` must be specified when updating ... `` で失敗する
  (API を呼ぶ前のチェックなので、リソースは何も変わらない)。
- `azurerm_kubernetes_cluster_node_pool.zones` は **4.16.0 未満では ForceNew** (replace) だった。
  4.16.0 で rotation に対応した。

つまり「plan が in-place」でも、**クラスターリソースは残るがノードは全台入れ替わる**、という見立て。
これを実機で裏取りする。

## SKU 選定 (japaneast, 2026-10-01 実測)

| VM サイズ | ゾーン | 備考 |
|-----------|--------|------|
| Standard_D2s_v3 / D2s_v5 / D2as_v5 / D2ds_v5 / B2s など | 1,2,3 | 3 ゾーン可 |
| **Standard_D2s_v6 / D2as_v6 / D2ads_v6 / D2als_v6** | **1,2 のみ** | **3 ゾーン指定は失敗する** |

クォータ: リージョン合計 10 vCPU / standardDSv3Family 10 / standardBSFamily 10 / DSv5・DASv5・DDSv5 は 0。
→ `Standard_D2s_v3` を採用。ノード数は rotation 中のピークも 10 vCPU に収まるよう system 1 + user 2。

## 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id を記入
terraform init

# 1. 初期状態を作成 (system [1,2] / user null)
terraform apply
az aks get-credentials -g akszone-rg -n aks-akszone --overwrite-existing

# 2. ZRS ワークロードを置く
kubectl apply -f k8s/zrs-app.yaml
kubectl rollout status deploy/zrs-writer
./check-zrs.sh before

# 3. plan の判定 (temporary_name_for_rotation あり / なし)
# (どちらも out/zones.tfplan に上書き保存するので、apply する「あり」を最後に実行する)
./plan-zones.sh '["1","2","3"]' '["1","2","3"]' false   # なし: apply すると失敗することも確認
./plan-zones.sh                                         # あり: これを apply する

# 4. 別ターミナルで ./watch.sh を起動してから apply
terraform apply out/zones.tfplan
./check-zrs.sh after
```

### 後片付け

```bash
kubectl delete -f k8s/zrs-app.yaml   # PV (ZRS ディスク) を先に消す
terraform destroy
```

## 検証結果 (2026-10-01, azurerm 4.80.0 / Terraform 1.15.5 / AKS 1.35.8 / japaneast)

### 1. plan の判定 — 別環境と同じく両方 in-place

```
azurerm_kubernetes_cluster.this            update
azurerm_kubernetes_cluster_node_pool.user  update
Plan: 0 to add, 2 to change, 0 to destroy.
```

apply 結果も `0 added, 2 changed, 0 destroyed`。**Terraform 上は最後まで replace にならない。**

### 2. 実際の動き — ノードプールは削除 -> 再作成される

`watch.sh` の記録 (JST)。apply 全体で約 12 分 (cluster 5m44s + node pool 6m9s)。

| 時刻 | 出来事 |
|------|--------|
| 10:52 | `systemtmp` [1,2,3] 作成開始 |
| 10:54 | 元の `system` を cordon + drain -> **削除** |
| 10:55 | `system` を [1,2,3] で**再作成** (VMSS 名 `system-19394187` -> `system-25789625`) |
| 10:57 | `systemtmp` 削除 |
| 10:58 | `usertmp` [1,2,3] x2 作成開始 |
| 11:00 | 元の `user` (ゾーン `0`) を cordon + drain (2 台同時) -> **削除**。Pod は `usertmp` (zone 2) へ移動 |
| 11:01 | `user` を [1,2,3] で**再作成** (VMSS 名 `user-38833229` -> `user-33595795`) |
| 11:03 | `usertmp` 削除。Pod は新 `user` (zone 3) へ**もう一度**移動 |

- **クラスターのリソースは残るが、ノード (VMSS) は全台作り直される。** 実質はノードプールの replace。
- user プールの Pod は **2 回** 移動する (元 -> 一時プール -> 新プール)。system プールのワークロードも同様。
- 一時プールが存在する間は同じ台数のノードが追加で必要 (vCPU クォータ・サブネットの IP に注意)。

### 3. ZRS PVC への影響 — データは保持、停止は 1 回あたり約 20 秒

| 項目 | 結果 |
|------|------|
| ディスク | 同じディスクを使い続けた (`timeCreated` 不変, `Premium_ZRS`, `zones: null`) |
| データ | 保持 (`marker` が初回作成時のまま) |
| PV の nodeAffinity | `japaneast-1`〜`4` と `""` (非ゾーン) をすべて許可。ゾーン `0` のノードにも [1,2,3] のノードにも付け替えられた |
| 書き込みの停止 | 21 秒 (02:00:56 -> 02:01:17 UTC) と 23 秒 (02:03:35 -> 02:03:58 UTC)。detach -> attach を含む |

ZRS なのでゾーンをまたぐ移動もできた。**LRS ディスクの場合は**、PV が特定ゾーン (またはゾーン `0`) に縛られるため、
非ゾーン -> ゾーンの変更で **Pod が Pending のまま起動できなくなる** 可能性が高い (今回は未検証)。

### 4. `temporary_name_for_rotation` 未設定時

- plan は同じく `update` (in-place) と表示される。
- apply は `` `temporary_name_for_rotation` must be specified when updating ... "default_node_pool.0.zones" `` で失敗。Azure 側は無変更。
- **ただし state の `default_node_pool.zones` は [1,2,3] に書き換わった。** refresh ありの plan なら差分は再検出されるが、
  `-refresh=false` の plan では system 側の差分が消える。

### 本番適用時の注意

1. `temporary_name_for_rotation` を両方のプールに設定しておく (無いと apply で失敗する)。
2. apply は**全ノードの入れ替え**として扱う。メンテナンス時間を取り、PDB・レプリカ数・ステートフルな Pod の停止時間を事前に確認する。
3. 一時プール分の vCPU クォータとサブネットの IP を確保する。
4. VM サイズが 3 ゾーンすべてで提供されているか確認する (japaneast の D*s_v6 系はゾーン 1,2 のみ)。
5. 別環境の azurerm が 4.16.0 未満なら、ユーザーノードプールは plan の時点で replace と表示される。
