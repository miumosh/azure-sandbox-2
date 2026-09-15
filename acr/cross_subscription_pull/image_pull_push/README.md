# ACR クロスサブスクリプション Pull (完全プライベート構成)

サブスクリプション **A** の ACR にあるイメージを、サブスクリプション **B** の ACR へ
コピーする構成。**両 ACR とも Premium / `public_network_access_enabled = false`（完全プライベート）**
を前提とし、**B 側 Runner VM が Private Endpoint 経由で `docker pull`(A) → `docker push`(B)** する。
認証は **Managed Identity + RBAC**。

```
 Subscription A (from)                       Subscription B (to)
┌─────────────────────────┐               ┌──────────────────────────────┐
│ ACR (Premium/private)   │               │ ACR (Premium/private)        │
│   └ Private Endpoint ───┼─ A VNet       │   └ Private Endpoint ─ B VNet │
│ 共有 Private DNS zone    │  10.10/16     │ Runner VM (UAMI) ────────────┤
│  privatelink.azurecr.io │◀── peering ──▶│  10.20/16                     │
│  (A・B 両方のレコード)   │               │  az acr login                 │
└─────────────────────────┘               │   → docker pull A             │
        ▲ AcrPull(UAMI on A)              │   → docker push B             │
        └───────────── AcrPush(UAMI on B) ─┴──────────────────────────────┘
```

- `from/` … A 側（ソース ACR）。ACR・VNet・PE・**共有 Private DNS ゾーン**を保有。B に依存しない独立構成。
- `to/` … B 側（取り込み先 ACR）。ACR・VNet・PE・**Runner VM**・UAMI に加え、循環依存を避けるため
  **A 側の配線**（ピアリング片側 / AcrPull / DNS VNet リンク）も `provider alias "src"` 経由でここから作成。

> 前提: A・B は **同一 Microsoft Entra テナント / 同一リージョン**。`to` を apply する実行主体は、
> **サブスク A 側にも書き込み権限**（ピアリング・ロール付与・DNS リンク作成）が必要。

---

## この方式を使うべきケース

> ⚠️ **訂正**: 当初このリポジトリは「private ソースからは `az acr import` できない」という**誤った前提**で
> 本 pull/push 方式を作った。実際には **ACR import は trusted service** であり、同一 Entra テナントなら
> public 無効の private ソースからでも import できる。詳細な経緯・真相・出典は
> [親ディレクトリ README](../README.md) を参照。多くのケースでは軽量な
> [`image_import`](../image_import/README.md) で十分。

それでも **この pull/push 方式が必要 / 有利**なのは次のような場合：

- **クロステナント × public 無効**：import は非対応。Runner で docker pull/push する必要がある。
- **実行時 private pull の検証**：B の AKS / Container Apps 等が **実行時に** A や B の private ACR から
  Pull する経路（VNet + Private Endpoint + Private DNS）を、まさに作って試したい。
- **import の信頼サービス機構に依存したくない** / レジストリ間コピーを完全に自分のネットワーク経路で完結させたい。

単に「private 同士でイメージをコピーしたい」だけなら、`image_import` の方が圧倒的に簡単（VNet/PE/VM 不要）。

---

## 必要な設定・作業まとめ（本実装 = A・B とも private）

| 対象 | 設定 | 管理場所 |
|------|------|----------|
| A: ソース ACR | Premium / public 無効 | `from/acr.tf` |
| A: ネットワーク | VNet + PE 用サブネット | `from/network.tf` |
| A: Private Endpoint | ソース ACR の PE | `from/private_endpoint.tf` |
| A: DNS | 共有 `privatelink.azurecr.io` ゾーン + A VNet リンク | `from/dns.tf` |
| B: 取り込み先 ACR | Premium / public 無効 | `to/acr.tf` |
| B: ネットワーク | VNet + PE/VM サブネット | `to/network.tf` |
| B: Private Endpoint | 取り込み先 ACR の PE（A の共有ゾーンへ登録） | `to/private_endpoint.tf` |
| B→A: ピアリング | 双方向 2 本（A 側は alias 経由） | `to/peering.tf` |
| B→A: DNS リンク | B VNet を A の共有ゾーンへリンク（alias 経由） | `to/dns.tf` |
| B: Identity | Runner 用 UAMI | `to/identity.tf` |
| B: RBAC | UAMI に AcrPull(A) + AcrPush(B) | `to/role.tf` |
| B: Runner | VM（docker / az CLI 同梱） | `to/vm.tf` |
| 実行 | `docker pull/push`（Runner VM 上） | 下記手順 |

---

## 適用手順

`to` が `from` の output（ACR/VNet/DNS ゾーンの ID 等）に依存する一方向の DAG。**`from` → `to` の順**で apply。

### 1. A 側 (`from`) を apply

```bash
cd from
cp terraform.tfvars.example terraform.tfvars   # 値を編集
terraform init && terraform apply

# B 側へ渡す値を取得
terraform output
```

### 2. B 側 (`to`) を apply

`from` の output（`source_acr_login_server` / `source_acr_id` / `source_rg_name` /
`source_vnet_id` / `source_vnet_name` / `source_dns_zone_id`）を `to/terraform.tfvars` に貼り付ける。

```bash
cd ../to
cp terraform.tfvars.example terraform.tfvars   # 上記の値 + B 側設定を編集
terraform init && terraform apply

terraform output runner_vm_ssh_cmd
terraform output pull_push_steps
```

---

## Pull 実行手順（Runner VM 上）

SSH で Runner VM に入り（`terraform output -raw runner_vm_ssh_cmd`）、`pull_push_steps` の手順を実行する。

```bash
# 1) UAMI でログイン (client_id は to の output: runner_identity_client_id)
az login --identity --username <runner_identity_client_id>

# 2) 両 ACR へログイン (login server は共有 Private DNS で私設 IP に解決される)
az acr login --name <source_acr_login_server>   # 例: crosssubsourceacrxxx.azurecr.io
az acr login --name <target_acr_login_server>   # 例: crosssubtargetacrxxx.azurecr.io

# 3) ソース A から pull → 先 B へ tag & push
docker pull <source_login_server>/<repo:tag>
docker tag  <source_login_server>/<repo:tag> <target_login_server>/<repo:tag>
docker push <target_login_server>/<repo:tag>
```

> Runner VM はクラウドイニットで `docker` / `azure-cli` を導入済み（初回起動後 1〜2 分）。

---

## 動作確認

```bash
# (事前) ソース A にイメージを用意 -- A がまだ public のうちに import で投入しておくのが簡単。
#        既に private の場合は A 側 VNet 内の踏み台等から push する。

# Runner VM 上で名前解決が私設 IP になっているか
nslookup <source_acr_login_server>   # => 10.10.x.x (A の PE)
nslookup <target_acr_login_server>   # => 10.20.x.x (B の PE)

# 上記「Pull 実行手順」を実行後、B 側に取り込まれたか確認
az acr repository list --name <target_acr_name> -o table
```

---

## 補足

- **片側だけ private にしたい**: `from/acr.tf` または `to/acr.tf` の `public_network_access_enabled`
  を `true` に戻す。public 側は PE/DNS リンクを省略でき、Runner の到達経路も簡略化できる（上表参照）。
- **RBAC 反映の遅延**: ロール付与直後は数十秒〜数分の伝播待ちが要る場合がある。
- **Runner を CI に置き換える**: 同等の到達性（A/B の PE へ届く VNet / Self-hosted runner）と UAMI 権限があれば、
  VM の代わりに GitHub Actions Self-hosted runner や Container 上で同じ pull/push を実行できる。
- **定期同期**: Pull 手順を cron / CI でスケジュール実行する。
