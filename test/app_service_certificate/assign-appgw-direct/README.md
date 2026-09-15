# assign-appgw-direct — 方式A: AppGW が KeyVault を直接参照（公開 HTTPS 検証）

`cert/` が用意した KeyVault 証明書を **AppGW の `ssl_certificate`(keyVaultSecretId) で直接ロード**し、
AGIC は Ingress アノテーション `appgw-ssl-certificate` で名前参照するだけ、の構成。
基盤 (VNet/AKS/AppGW/AGIC/RBAC) は `aks/agic/helm/single_access_single_appgw` を土台にしている。

## この方式の要点
- 秘密鍵はクラスタに出ない (KeyVault ⇄ AppGW のみ)。
- ローテーションは AppGW が KeyVault を自動追従 (versionless secret id)。
- `spec.tls` は使わない。
- **App Service Certificate を使うならこちらが素直**（方式B は更新追従が壊れる）。

> 本 README は **方式A の手順とハマりどころ**。
> 検証全体の知見（エラー全文・原因・デバッグ手順・一次情報）は [`../findings.md`](../findings.md)、
> 方式A/B の設計比較は [`../keyvault_cert_using_pattern.md`](../keyvault_cert_using_pattern.md)。

## 検証経路: 公開 HTTPS（ローカル PC から）

AppGW の **public frontend** を使い、`example.com` に A レコードを作って
**ローカル PC から素の `curl` / ブラウザ**で検証する。

```
ローカル PC ──HTTPS──▶ azure-app-service-cert-check.example.com
                              │ (A record → dns.tf)
                              ▼  AppGW Public IP
                        AppGW  TLS 終端: KeyVault の App Service Certificate
                              │ HTTP
                              ▼
                        AKS Pod (aks-helloworld)
```

`--resolve` も `-k` も使わない。**`-k` なしでチェーン検証が通ることが合格条件**であり、
それが「有料の App Service Certificate が正しく載っている」ことの実証になる
（self_signed モードなら当然ここは `-k` なしでは通らない）。

> テスト VM + private frontend (10.0.1.10) を使う旧構成は撤去した。
> 公開経路なら VM も SSH も不要で、実運用と同じ経路をそのまま検証できる。

### 3 つの FQDN は一致必須
| 場所 | 定義 |
|---|---|
| 証明書の CN | `cert/` の `var.common_name` |
| Ingress の host | `k8s/ingress.yaml` の `spec.rules[].host` |
| A レコード | `dns.tf`（`var.dns_record_name` + `var.dns_zone_name`） |

いずれも `azure-app-service-cert-check.example.com`。

## 前提
- `cert/` を apply 済み。`cert_source=app_service_order` の場合は **Issued まで完了**していること
  (`data.azurerm_key_vault_secret` が plan 時に実体を読むため)。

## 手順
```bash
# 1) cert/ の出力を tfvars へ
terraform -chdir=../cert output

# 2) 基盤 + 証明書配線 + DNS A レコードを apply
cp terraform.tfvars.sample terraform.tfvars   # 値を編集
terraform init && terraform apply

# 3) AGIC を Helm 導入 (MCR の OCI レジストリから。旧 Helm リポジトリは公開停止済み)
$(terraform output -raw aks_get_credentials_cmd)
helm install agic \
  oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure \
  --version 1.9.11 \
  --namespace kube-system \
  --set appgw.subscriptionId=$(terraform output -raw subscription_id) \
  --set armAuth.identityClientID=$(terraform output -raw agic_identity_client_id) \
  -f k8s/agic-values.yaml
#   ※ release 名は "agic" 固定。identity.tf の federated credential の subject が
#      system:serviceaccount:kube-system:agic-sa-ingress-azure に依存している

# 4) デモアプリ + Ingress
kubectl apply -f k8s/ingress.yaml

# 5) AGIC が AppGW を再構成するのを待つ (provisioningState が Updating → Succeeded)
az network application-gateway show -g certdirect-rg -n certdirect-appgw \
  --query "{prov:provisioningState,op:operationalState}" -o json
```

## 検証（ローカル PC から）
```bash
# 1) A レコードが公開 DNS に出ているか
dig +short A azure-app-service-cert-check.example.com @8.8.8.8
#    → terraform output appgw_public_ip と一致すること

# 2) ★本命: -k なし・--resolve なしの素の curl でチェーン検証込みに通ること
curl -v $(terraform output -raw test_url)
#    期待: SSL certificate verify ok / HTTP 200 / aks-helloworld の HTML

# 3) 提示された証明書が cert/ の実体と一致するか
openssl s_client -connect azure-app-service-cert-check.example.com:443 \
  -servername azure-app-service-cert-check.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
#    期待: subject = CN = azure-app-service-cert-check.example.com
#          issuer  = ... GoDaddy TLS Intermediate CA DV - R1v1
#          notAfter が cert/ で確認した値と一致

# 4) HTTP → HTTPS リダイレクト (ingress の ssl-redirect: "true")
curl -sI http://azure-app-service-cert-check.example.com | head -1
#    期待: 301
```
`-k` なしで verify が通れば、**中間証明書まで含めて正しく提示されている**ことも同時に証明される
（チェーンが欠けていれば verify が落ちる）。ブラウザで開いて鍵マークが出ることも確認する。

## ハマりどころ（実検証で踏んだもの）

### 1. ★AGIC が AppGW を更新できない — `LinkedAuthorizationFailed` (403)
**方式A 固有。これが本検証で最も詰まった点。**

AGIC Pod は起動し、AppGW の設定も正しく組み立てるのに、**Ingress が一切反映されない**
（AppGW は placeholder リスナーのまま）。AGIC のログを見て初めて分かる:

```
E controller.go:157] network.ApplicationGatewaysClient#CreateOrUpdate: StatusCode=403
  Code="LinkedAuthorizationFailed"
  Message="The client '<agic-uai>' has permission to perform action
    'Microsoft.Network/applicationGateways/write' on scope '.../certdirect-appgw';
    however, it does not have permission to perform action(s)
    'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action' on the linked scope(s)
    '.../userAssignedIdentities/certdirect-appgw-kv-identity'"
```

**原因**: 方式A では AppGW 本体に「KeyVault 読み取り用の UserAssigned Identity」を紐付けている。
AGIC が AppGW を更新 (PUT) すると、リクエストボディに**その UAI への参照が含まれる**。
ARM は「UAI を参照するリソースを書く側」に、その UAI への `assign/action` を要求する。
AGIC は AppGW の Contributor ではあるが、**UAI 側の権限を持っていない**ため 403。

**対処**: AGIC の identity に `Managed Identity Operator` を、**その UAI 1個だけをスコープ**に付与する
（`role.tf` の `azurerm_role_assignment.agic_mi_operator_appgw_kv`）。

```hcl
resource "azurerm_role_assignment" "agic_mi_operator_appgw_kv" {
  scope                = azurerm_user_assigned_identity.appgw_kv.id # UAI 1個に限定
  role_definition_name = "Managed Identity Operator"                # assign/action を含む
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}
```

**方式B (assign-agic-csi) はこの問題が起きない** — AppGW に UAI を付けず、証明書は CSI 経由で
K8s Secret から AGIC がアップロードするため、AppGW の PUT ボディに UAI 参照が入らない。
一般的な AGIC 例 (`aks/agic/helm/*`) にもこのロールが無いのは同じ理由。

> エラーが AGIC の Pod ログにしか出ないのが厄介。`kubectl get ingress` は正常に見え、
> AppGW も `Succeeded` のまま。**Ingress が反映されないときはまず AGIC のログを見る**。
> `kubectl logs -n kube-system -l app=ingress-azure --tail=50`

### 2. AGIC の Helm リポジトリが公開停止 → OCI (MCR) を使う
従来の手順にある
`helm repo add ... https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/` は
**もう使えない**:

```
Error: looks like "https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/"
is not a valid chart repository or cannot be reached:
failed to fetch .../index.yaml : 409 Public access is not permitted on this storage account.
```

→ `oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure` を使う（上記手順参照）。
利用可能なバージョンは
`curl -s https://mcr.microsoft.com/v2/azure-application-gateway/charts/ingress-azure/tags/list`。

### 3. AppGW → KV アクセスポリシーの依存が暗黙依存では足りない
AppGW は「作成時」に KeyVault シークレットを実際に読みに行く。
`identity_ids` や `data.azurerm_key_vault_secret` への暗黙依存だけでは
`azurerm_key_vault_access_policy.appgw_kv` の完了を待たないため、
**権限付与前に AppGW を作って失敗**しうる。`appgw.tf` に `depends_on` を明示済み。
AppGW の作成は 10 分以上かかるので、この失敗はコストが高い。

### 4. AGIC の `usePrivateIP`
本構成は public frontend のみ。`usePrivateIP: true` のままだと AGIC が private frontend を
探してリスナーを作れず、Ingress が反映されない → `false` に設定済み。

### 5. AppGW の構成反映にはラグがある
AGIC がリスナーを作った直後は AppGW が `provisioningState: Updating` で、
**443 が Connection refused になる**。焦らず `Succeeded` / `operationalState: Running` を待つ。

### 6. `ignore_changes` の漏れが AGIC の設定を消しにいく
AGIC が AppGW に作るものを `lifecycle.ignore_changes` に挙げ漏れると、
**次に `terraform apply` した瞬間に Terraform がそれを削除しようとする**（AGIC が作り直すので奪い合う）。

実際に踏んだのは `redirect_configuration`:
ingress の `ssl-redirect: "true"` で AGIC が HTTP→HTTPS リダイレクト設定を作るが、
これが `ignore_changes` に無かったため plan に「削除」として出た。→ 追加済み。

**apply 後に必ず `terraform plan` を実行して `No changes` を確認すること。**
差分が残っていたら、それは「次の apply で壊れるもの」。

なお `ssl_certificate` は **ignore しない**。方式A では Terraform が KeyVault リンクを所有するのが
要点であり、ここが方式B と逆になる。

### 7. Azure 側の正規化による恒久 diff（2件）
apply 後も plan が `Plan: 0 to add, N to change` のままになる。Azure が値を正規化して返すため。
config を Azure の実値に合わせて解消済み:

| 対象 | Azure が返す実値 |
|---|---|
| `azurerm_subnet.appgw` の delegation `actions` | `Microsoft.Network/virtualNetworks/subnets/join/action`（`.../subnets/action` と書くと毎回差分） |
| `azurerm_kubernetes_cluster.aks` の `default_node_pool.upgrade_settings` | `max_surge = "10%"`（省略すると provider が消そうとして毎回差分） |

### 8. その他
- **順序**: cert/ の証明書が KV に存在しないと apply/plan が失敗する。
- **frontend_port**: AGIC が HTTPS 用に 443 を追加するため appgw.tf の `ignore_changes` に追加済み。
- **appgw-subnet に NSG は付けない**: AppGW v2 のサブネットに NSG を付けると 80/443 の許可だけでは
  足りず、GatewayManager からの 65200-65535 inbound などが別途必要になり、抜けると Unhealthy になる。
  検証の本筋 (証明書) と無関係な失敗要因なので付けていない (sg.tf のコメント参照)。

## この UAI に絡む権限は 2 系統（両方必須）

```
                    ① secret Get (access policy)
  [appgw-kv-identity] ─────────────────────────▶ [KeyVault]   AppGW が証明書を「読む」
        ▲
        │ ② Managed Identity Operator (assign/action)
        │    ※これが無いと LinkedAuthorizationFailed
  [agic-identity] ──── Contributor ────▶ [AppGW]              AGIC が AppGW を「更新する」
```

①は `cert_ref.tf`、②は `role.tf`。片方だけでは動かない。

## 検証結果（2026-07-12 実施・成功）

`cert/` を `cert_source = "app_service_order"` で用意した本物の GoDaddy 証明書を使用。
**ローカル PC から `-k` なし・`--resolve` なしの素の curl で HTTPS が通ることを確認**。

```
$ curl -sS -o /dev/null -w "HTTP %{http_code} | SSL verify: %{ssl_verify_result}\n" \
    https://azure-app-service-cert-check.example.com
HTTP 200 | SSL verify: 0        ← 0 = 検証 OK

$ openssl s_client -connect azure-app-service-cert-check.example.com:443 ...
subject = CN = azure-app-service-cert-check.example.com
issuer  = C = US, O = GoDaddy.com, CN = GoDaddy TLS Intermediate CA DV - R1v1
notAfter= Jan 26 13:04:20 2027 GMT          ← cert/ で確認した値と一致

depth=0 CN = azure-app-service-cert-check.example.com
depth=1 GoDaddy TLS Intermediate CA DV - R1v1
depth=2 GoDaddy Root CA - R1
depth=3 Go Daddy Root Certificate Authority - G2
Verification: OK / Verify return code: 0 (ok)   ← チェーン検証も通過

$ curl -sI http://azure-app-service-cert-check.example.com
HTTP 301 → https://azure-app-service-cert-check.example.com/   ← ssl-redirect
```

`-k` なしで通ったことにより、**KeyVault の App Service Certificate が AppGW に正しくロードされ、
中間証明書まで含めて提示されている**ことが同時に実証された。
