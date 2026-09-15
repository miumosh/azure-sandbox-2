# 検証知見まとめ — App Service Certificate × KeyVault × AppGW/AGIC

2026-07-12 に実施した実検証で判明した事実・踏んだ罠・その原因と対処をまとめる。
ドキュメントに書かれていない、あるいは書かれていても見落としやすい点を優先して記録している。

- 検証環境: サブスクリプション `従量課金` / DNS ゾーン `example.com` (rg-dns) / japaneast
- 対象: [`cert/`](cert/) → [`assign-appgw-direct/`](assign-appgw-direct/)（方式A） / [`assign-agic-csi/`](assign-agic-csi/)（方式B）
- 結果: **3 つとも成功**。ただし方式B は追加の import 工程が必須（後述）。

---

## 0. 結論（先に読む）

### 0-1. App Service Certificate を使うなら方式A が素直

| | 方式A: AppGW が KV を直接参照 | 方式B: CSI → K8s Secret |
|---|---|---|
| **ASC 更新への追従** | ✅ **自動**（versionless secret id） | ❌ **しない**（import がスナップショットのため） |
| ASC を使う際の追加作業 | なし | **PFX を KV に「証明書オブジェクト」として import し直す必要** |
| 秘密鍵の所在 | KeyVault ⇄ AppGW のみ | K8s Secret (etcd) に materialize |
| 必要な追加 RBAC | AGIC に `Managed Identity Operator`（UAI スコープ） | 不要 |
| AppGW の ssl_certificate 所有者 | **Terraform**（KV リンク） | **AGIC**（アップロードしたデータ。`keyVaultSecretId: null`） |

方式B が素直に動かない根本原因は下記 **1-1**（ASC は KV 証明書オブジェクトを作らない）に集約される。

### 0-2. すべての罠の根源はこの 1 つの性質

> **App Service Certificate は KeyVault に「証明書オブジェクト」を作らない。
> 素のシークレットに、base64 エンコードされた PFX を入れるだけ。**

この一点から、方式B の破綻・ポータルで見つからない問題・CSI の設定ミスが芋づる式に発生する。

---

## 1. 証明書の発行（cert/）

### 1-1. ★KV には「シークレット」だけができ、「証明書オブジェクト」はできない

```bash
$ az keyvault certificate show --vault-name kv-appgwcert-xxxx -n appgw-tls-cert
ERROR: (CertificateNotFound) A certificate with (name/id) appgw-tls-cert was not found in this key vault.

$ az keyvault secret show --vault-name kv-appgwcert-xxxx -n appgw-tls-cert --query "{contentType:contentType,tags:tags}"
{
  "contentType": "application/x-pkcs12",
  "tags": {
    "CertificateState": "Ready",
    "SerialNumber": "009497D49F2599E000",
    "Thumbprint": "575ED27A24F7907FBB1FE60D0A80BD202FAAF183"
  }
}
```

- シークレットの**値そのものが base64 文字列**（`az keyvault secret download --encoding base64` でそのまま PFX になる）。
- 参照側は必ず **secret** として読むこと:
  - AppGW: `ssl_certificate.key_vault_secret_id`（OK）
  - CSI: `objectType: secret`（`certificate` だと公開鍵のみで TLS に使えない）
- `self_signed` モードは KV 証明書オブジェクトも作るので、**両モードの唯一の非対称点**。
  ただし assign-* はどちらも secret 参照なので、方式A は無改変で切り替わる（方式B は 3-1 参照）。

**ドメイン検証前は空**: Issued になるまでシークレットは値を持たず、タグが
`CertificateState: Initialized` のプレースホルダとして存在する。逆に言うと
**このプレースホルダが作られていれば、KV 紐付けと権限は正しい**（良い中間チェックポイント）。

### 1-2. ★DNS 検証 TXT は「ルートドメイン `@`」に置く

CN がサブドメイン（`azure-app-service-cert-check.example.com`）でも、
TXT はサブドメイン側ではなく **ゾーンのルート `@`** に置く。公式ドキュメント原文:

> For domain verification via DNS TXT record for either the root domain (for example, `contoso.com`)
> or the subdomain (for example, `www.contoso.com` or `test.api.contoso.com`) and **regardless of the
> certificate SKU, you need to add a TXT record at the root domain level. Use `@` for the name** and
> the domain verification token for the value in your DNS record.
>
> — [Manage App Service Certificates](https://learn.microsoft.com/azure/app-service/configure-ssl-app-service-certificate)

直感に反するので、サブドメインに TXT を置いて「いつまでも Issued にならない」と悩みがち。

**A レコードは不要**: TXT 検証は「ドメインの所有権」の証明であり、証明書の対象ホストが
名前解決する必要はない。（もう一方の Manual verification である *HTML page verification* を
選んだ場合は A レコードと Web サーバ応答が必須になる。）

**検証は自動で走る**: TXT が公開伝播していれば CA (GoDaddy) が自動検出し、数分で Issued になった。
`verifyDomainOwnership` API を叩く必要はなかった（叩いたら
`CertificateResellerWebService_INVALID_STATE: This request is no longer Pending Validation` = 既に検証済み）。

### 1-3. ★KV に書き込むのは CertificateRegistration RP（App Service RP ではない）

ポータルで作成すると KV に access policy が **2 つ**付く。証明書の実体 (PFX) を書き込むのは前者。

| RP | appId | 役割 |
|---|---|---|
| `Microsoft.Azure.CertificateRegistration` | `f3c21649-0979-4721-ac85-b0216b2cf413` | ★**KV に PFX を書き込む主体** |
| `Microsoft Azure App Service` | `abfa0a7c-a6b6-4736-8310-5855508787cd` | KV から証明書を読む側 |

**App Service RP だけを許可すると、Issued になっても KV シークレットは空
（`CertificateState: Initialized`）のまま値が入らない。** 原因が分かりにくい失敗になる。

権限は **secret の Get/List/Set/Delete** が本質（実体はシークレットとして入るため）。
公式の表は certificate 側にも "Set" と書いているが、**KV の certificate 権限に `Set` は存在せず**、
azurerm の validation で落ちる。certificate 側は付けなくてよい。

### 1-4. RP を登録しないと SP がテナントに存在しない（順序依存）

```bash
$ az ad sp show --id f3c21649-0979-4721-ac85-b0216b2cf413
ERROR: Resource 'f3c21649-...' does not exist or one of its queried reference-property objects are not present.
```

→ object id を引く前に RP 登録が必要:

```bash
az provider register -n Microsoft.CertificateRegistration --wait
az ad sp show --id f3c21649-0979-4721-ac85-b0216b2cf413 --query id -o tsv
```

さらに **`Microsoft.CertificateRegistration` は azurerm provider の自動登録セットに含まれない**。
`resource_provider_registrations` の legacy / core / extended / all の**どのセットにも入っていない**
（provider の `required.go` を読んで確認。公式ドキュメントには各セットの内訳が載っていない）。
→ `providers.tf` で `resource_providers_to_register` に明示するか、上記 az コマンドで先に登録する。

### 1-5. 有効期間は「1 年」にならない

`validity_in_years = 1` で発注しても、実際に発行された証明書は
**2026-07-12 → 2027-01-26（約 6.5 ヶ月）**だった。GoDaddy 側の発行ポリシーに従う。

### 1-6. `validity_in_years` が恒久 diff になる

発行後、API は `validity_in_years` に **0** を返す。config の `1` と食い違うため、
apply 済みでも plan が毎回 `1 to change` になる。
**有料の証明書オーダーに PATCH を打ちたくない**ので `ignore_changes` で抑止する。

```hcl
lifecycle { ignore_changes = [validity_in_years] }
```

### 1-7. ポータルのどこを見れば証明書を確認できるか

KeyVault 連携の証明書は **AppGW の画面では中身が見えない**。AppGW の `sslCertificates` が
持っているのは参照だけで、Subject も有効期限も拇印も入っていない:

```json
{
  "name": "appgw-tls-cert",
  "keyVaultSecretId": "https://kv-appgwcert-xxxx.vault.azure.net/secrets/appgw-tls-cert",
  "provisioningState": "Succeeded"
}
```
（PFX を直接アップロードした場合は `publicCertData` が入り、ポータルでも中身が見える）

| 見たいもの | ポータルの場所 |
|---|---|
| AppGW に紐付いているか（名前・KV 参照） | Application Gateway → **リスナー** → HTTPS リスナー |
| 証明書の中身（Subject / 状態 / 有効期限） | **App Service 証明書** → 該当オーダー → 概要 |
| KV の実体（拇印・シリアル・状態） | Key Vault → **シークレット** → タグ |

> Key Vault では **「証明書」タブではなく「シークレット」タブ**を見る。
> 1-1 のとおり証明書オブジェクトが無いので「証明書」タブは空で、探して「無い！」となりがち。

拇印は KV シークレットのタグと、実際にエンドポイントが提示する証明書で一致する:

```bash
echo | openssl s_client -connect <fqdn>:443 -servername <fqdn> 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha1
# → KV タグの Thumbprint と一致
```

### 1-8. ★KeyVault への格納は「自動」ではない — 明示的な紐付けが必要

ポータルの「証明書の構成 → **手順1: 保存 (Store)**」は、**独立した ARM 子リソース**を作っている。
ウィザードが案内するので自動に見えるが、明示的に作らないと**証明書は KeyVault に入らない**。

```bash
$ az rest --method get --url ".../certificateOrders/appgw-cert-order/certificates?api-version=2023-12-01"
[{
  "name": "appgw-tls-cert",
  "type": "Microsoft.CertificateRegistration/certificateOrders/certificates",   ← 独立した子リソース
  "keyVaultId": ".../vaults/kv-appgwcert-xxxx",
  "keyVaultSecretName": "appgw-tls-cert",
  "provisioningState": "Succeeded"
}]
```

**azurerm にこの子リソース用のネイティブリソースは無い。**
→ `cert/cert_order.tf` では `azurerm_resource_group_template_deployment` (ARM テンプレート) で代替している。

#### なぜ「保存先の選択」ではなく「必須の出口」なのか

**App Service Certificate は PFX を直接ダウンロードさせてくれない。KeyVault が唯一の受け渡し口。**
つまり「KeyVault に保存しますか？」という任意オプションではなく、
**紐付けないと証明書を取り出す手段が存在しない**。
ポータルが 手順1(保存) → 手順2(検証) の順を強制するのはこのため。
紐付ける前に発行されても、証明書の行き場が無い。

#### 実際の状態遷移（観測できたこと）

```
1. オーダー作成              → status: PendingIssuance / KV には何も無い
2. 紐付け(子リソース)を作成   → KV に「空のプレースホルダ」が出現
                               tags: { CertificateState: "Initialized" }   ← 値はまだ無い
3. DNS TXT 検証が通り Issued → RP が自動で PFX を書き込む
                               tags: { CertificateState: "Ready", Thumbprint: "575ED2..." }
```

**ステップ2で空のシークレットが現れるかどうかが、良い中間チェックポイント。**
- 現れる → 紐付けと RP 権限は正しい
- Issued なのに `Initialized` のまま → **1-3 の RP 取り違え**を疑う

**「自動」なのは書き込み動作の方**: 紐付けさえすれば、あとは RP が勝手に PFX を KV に入れる。
利用者が PFX を触ることはない。更新時も同じシークレットに新バージョンが自動で書かれる。

### 1-9. ★ARM/Terraform 経由では KeyVault に削除ロックが付かない（運用リスク）

公式ドキュメントの FAQ「証明書作成プロセスは KeyVault に何を変更するか」にはこうある:

> - Adds two access policies in the vault ...
> - Creates a **delete lock called `AppServiceCertificateLock`** on the key vault to prevent
>   accidental deletion of the key vault.

しかしこれは **ポータルのウィザード経由の場合だけ**。ARM API / Terraform で作ると**付かない**:

```bash
$ az lock list --resource-group rg-appgw-cert-test
（空）
```

1-8 のとおり **証明書の実体は KeyVault にしか無い**（ASC は PFX を直接ダウンロードさせない）。
KeyVault を誤削除すると証明書を取り出す手段が消える。
また**証明書オーダーの削除は失効を意味し、取り消し不可**。

→ **自分で削除ロックを付ける**。`cert/locks.tf`:

```hcl
resource "azurerm_management_lock" "key_vault" {
  name       = "AppServiceCertificateLock" # ポータルが付ける名前に合わせる
  scope      = azurerm_key_vault.this.id
  lock_level = "CanNotDelete"
}

resource "azurerm_management_lock" "cert_order" {
  count      = var.cert_source == "app_service_order" ? 1 : 0
  name       = "CertOrderDoNotDelete"
  scope      = azurerm_app_service_certificate_order.this[0].id
  lock_level = "CanNotDelete"
}
```

> ⚠️ **このロックは「Terraform の外からの誤削除」しか防げない。**
> `terraform destroy` はロック → 対象リソースの順に消すため、destroy は止められない。
> 本当に守りたいなら **証明書を Terraform 管理から外す**（= CLI 運用）方が確実。
> → [`cert/az_cli_pattern.md`](cert/az_cli_pattern.md)

### 1-10. ★証明書の自動更新は「3 層の連鎖」

「自動更新を有効にしたのに反映されない」は、どの層で切れているかを切り分ける。

| # | 何が自動か | 設定箇所 | 切れると |
|---|---|---|---|
| 1 | **CA が証明書を再発行** | `azurerm_app_service_certificate_order.auto_renew`（既定 `true`。本検証では `false`） | そもそも更新されない |
| 2 | **KV シークレットに新バージョンが書かれる** | 設定不要。**紐付け(1-8) と RP 権限(1-3) が生きていれば RP が自動でやる** | Issued なのに KV が古いまま |
| 3 | **AppGW が新バージョンを拾う** | AppGW に **versionless secret id** を渡す（~4h ポーリング） | KV は新しいのに AppGW が古い証明書を出す |

- 3 は `assign-appgw-direct/appgw.tf` の `data.azurerm_key_vault_secret.cert.versionless_id`。
  **バージョン付き id を渡すと固定されて追従しない。**
- **方式B は 2 → 3 が構造的に切れている**（import したコピーは ASC 更新に追従しない → 3-1）。

```bash
# 現在の設定を確認
az rest --method get --url ".../certificateOrders/appgw-cert-order?api-version=2023-12-01" \
  --query "properties.{autoRenew:autoRenew,next:nextAutoRenewalTimeStamp,expiry:expirationTime}"
# autoRenew: true なら nextAutoRenewalTimeStamp に日時が入る（期限32日前）
```

#### ⚠️ 購入証明書はドメインの**自動再検証をしない**

> Unlike the free App Service managed certificate, purchased App Service certificates
> **don't have automated domain reverification. Failure to verify domain ownership results in
> failed renewals.**
>
> If you haven't verified the domain in the last **395 days**, App Service certificates require
> domain verification during a renewal, autorenewal, or rekey process.

→ **検証で作ったルートの TXT レコードは消さない方が安全。**
また、更新は**課金される**（1 年分）。

### 1-11. CAA レコード

ゾーンに CAA がある場合は GoDaddy を明示許可する必要がある（`0 issue godaddy.com`）。
CAA 未設定のゾーンなら不要（今回は未設定だったので何もしていない）。

### 1-12. 購入できないサブスクリプション種別に注意

App Service Certificate はクレジット系（無料試用・Visual Studio 等）のサブスクリプションでは
購入できない。今回は**従量課金**サブスクリプションを使用した。

### 1-13. ★そもそも証明書を Terraform で管理すべきか

本検証を通して、**証明書オーダーは Terraform 管理に向かない**ことが分かった。

| 観点 | 実情 |
|---|---|
| **destroy が破壊的で不可逆** | 削除 = **証明書の失効**。`terraform destroy` の巻き添えで消えると復旧できない |
| **有料・一点物** | 誤って作り直すと再課金（~$69/年）。「壊して作り直す」思想と噛み合わない |
| **azurerm にネイティブリソースが無い** | KV 紐付け（1-8）は azurerm 未対応 → **ARM テンプレートを書く羽目になる**（結局 IaC の旨みが薄い） |
| **恒久 diff** | 1-6 のとおり `ignore_changes` が必要 |
| **ライフサイクルが極端に長い** | 作るのは 1 回、あとは年 1 回の更新だけ |
| **状態が Azure 側で勝手に変わる** | PendingIssuance → Issued、更新による新バージョン発行など |
| **ロックが効かない** | 1-9 のロックは `terraform destroy` を止められない（ロック → 対象の順に消すため） |

一方 **KeyVault / DNS ゾーン / assign-\* は Terraform 管理が向く**（冪等・再作成可能・destroy が怖くない）。

> **推奨: 「証明書オーダーだけ az CLI、周辺（KV/DNS/AppGW/AKS）は Terraform」というハイブリッド。**
> CLI 手順は [`cert/az_cli_pattern.md`](cert/az_cli_pattern.md) にまとめた。
> `assign-*` は KV を `data` 参照するだけなので、**cert/ を CLI 運用に切り替えても assign-\* は無改変**。

なお **az CLI に「証明書を購入する」コマンドは存在しない**（`az webapp config ssl import` は
「既にある ASC を Web App に取り込む」だけ）。CLI 運用でも結局 `az rest` で ARM API を直接叩く。

---

## 2. 方式A: AppGW が KeyVault を直接参照（assign-appgw-direct）

### 2-1. ★AGIC が AppGW を更新できない — `LinkedAuthorizationFailed` (403)

**方式A 固有。本検証で最も詰まった点。**

**症状**: AGIC Pod は起動し、AppGW の設定も正しく組み立てるのに **Ingress が一切反映されない**
（AppGW は placeholder リスナーのまま）。`kubectl get ingress` は正常に見え、AppGW も `Succeeded`。
**エラーは AGIC の Pod ログにしか出ない。**

```
E controller.go:157] network.ApplicationGatewaysClient#CreateOrUpdate: StatusCode=403
  Code="LinkedAuthorizationFailed"
  Message="The client '<agic-uai>' with object id '<...>' has permission to perform action
    'Microsoft.Network/applicationGateways/write' on scope '.../certdirect-appgw';
    however, it does not have permission to perform action(s)
    'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action' on the linked scope(s)
    '.../userAssignedIdentities/certdirect-appgw-kv-identity' (respectively)
    or the linked scope(s) are invalid."
```

**原因**: 方式A では AppGW 本体に「KeyVault 読み取り用の UserAssigned Identity」を紐付けている。
AGIC が AppGW を更新 (PUT) すると、**リクエストボディにその UAI への参照が含まれる**。
ARM は「UAI を参照するリソースを書く側」に、その UAI への `assign/action` を要求する。
AGIC は AppGW の Contributor ではあるが、**UAI 側の権限を持っていない**ため 403。

**対処**: AGIC の identity に `Managed Identity Operator` を、**その UAI 1 個だけをスコープ**に付与。

```hcl
resource "azurerm_role_assignment" "agic_mi_operator_appgw_kv" {
  scope                = azurerm_user_assigned_identity.appgw_kv.id # UAI 1個に限定
  role_definition_name = "Managed Identity Operator"                # assign/action を含む
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}
```

一般的な AGIC の例（`aks/agic/helm/*`）にこのロールが無いのは、AppGW に UAI を付けないから。
**方式B でも不要**（3 章参照）。

> **教訓: Ingress が AppGW に反映されないときは、まず AGIC のログを見る。**
> `kubectl logs -n kube-system -l app=ingress-azure --tail=50`

### 2-2. この UAI に絡む権限は 2 系統ある（両方必須）

```
                    ① secret Get (KV access policy)          [cert_ref.tf]
  [appgw-kv-identity] ─────────────────────────▶ [KeyVault]   AppGW が証明書を「読む」
        ▲
        │ ② Managed Identity Operator (assign/action)          [role.tf]
        │   ※これが無いと LinkedAuthorizationFailed
  [agic-identity] ──── Contributor ────▶ [AppGW]              AGIC が AppGW を「更新する」
```

片方だけでは動かない。①だけだと AGIC が AppGW を更新できず、②だけだと AppGW が証明書を読めない。

### 2-3. AppGW → KV アクセスポリシーへの `depends_on` が必須

AppGW は**作成時**に `ssl_certificate.key_vault_secret_id` を実際に読みに行く。
UAI に KV の Get 権限が付いた**後**でないと作成に失敗する。

暗黙依存だけでは足りない:
- `identity_ids` → UAI（ID があるだけ。権限とは無関係）
- `key_vault_secret_id` → `data.azurerm_key_vault_secret`（Terraform 実行者の権限で読むだけ）

どちらも `azurerm_key_vault_access_policy` の完了を待たない。**AppGW の作成は 10 分以上かかる**ので、
この失敗はコストが高い。

```hcl
depends_on = [azurerm_key_vault_access_policy.appgw_kv]
```

### 2-4. AGIC の `usePrivateIP`

public frontend のみの構成で `usePrivateIP: true` のままだと、AGIC が private frontend を探して
リスナーを作れず、Ingress が反映されない。公開検証では `false`。

### 2-5. AppGW の構成反映にはラグがある

AGIC がリスナーを作った直後は AppGW が `provisioningState: Updating` で、
**443 が Connection refused になる**。`Succeeded` / `operationalState: Running` を待つ。

```bash
az network application-gateway show -g <rg> -n <appgw> \
  --query "{prov:provisioningState,op:operationalState}" -o json
```

---

## 3. 方式B: CSI で K8s TLS Secret に同期（assign-agic-csi）

### 3-1. ★★App Service Certificate は CSI と素直に組み合わせられない

**本検証で最大の発見。** 1-1（ASC は KV 証明書オブジェクトを作らない）がここで牙を剥く。

#### 症状①: Pod は Running なのに K8s Secret が生成されない

`kubectl get pod` も `kubectl get secretproviderclass` も正常。CSI マウントも成功している
（`SecretProviderClassPodStatus` は `mounted: true`）。なのに Secret だけが無い。
**エラーは CSI ドライバのログにしか出ない。**

```bash
kubectl logs -n kube-system -l app=secrets-store-csi-driver -c secrets-store
```
```
E secretproviderclasspodstatus_controller.go:318] "failed to get data in spc for secret"
  err="failed to get cert data from file .../appgw-tls-cert,
       err: pkcs12: error reading P12 data: asn1: structure error:
            tags don't match (16 vs {class:1 tag:13 ...}) pfxPdu @2"
```

#### 原因: プロバイダとドライバの責任分界

CSI の Azure プロバイダは、**KV に「証明書オブジェクト」がある場合にだけ** PKCS12 → PEM 変換をする。
素のシークレット（= ASC）だと変換されず、代わりに **CSI ドライバ側**が PKCS12 を解釈することになる。

| SecretProviderClass の設定 | 書き出されるファイル | 結果 |
|---|---|---|
| `objectEncoding` 無し（既定 utf-8） | base64 **文字列**のまま | ドライバの PKCS12 パースが asn1 エラー → **Secret が生成されない** |
| `objectEncoding: base64` | バイナリ PFX | Secret は生成されるが **中身が壊れている**（下記） |
| `objectFormat: pem` | バイナリ PFX | 同上（プロバイダは PEM 変換してくれない） |

#### 症状②: Secret はできるが `tls.crt` が壊れている

バイナリ PFX を CSI ドライバが解釈すると、Go の `pkcs12.ToPEM` が
**PKCS#12 のバッグ属性を PEM ヘッダとして出力**してしまう:

```
-----BEGIN CERTIFICATE-----
localKeyId: 01000000          ← OpenSSL は Proc-Type 以外のヘッダを解釈できない

MIIHnjCCBYag...
```

さらに**チェーンが逆順**になる（ルートが先頭・リーフが最後）:

```
[1] Go Daddy Root Certificate Authority - G2
[2] GoDaddy TLS Root CA - R1
[3] GoDaddy TLS Intermediate CA DV - R1v1
[4] CN = azure-app-service-cert-check...    ← リーフが最後 & パース不能
```

結果、AGIC が `tls.crt` + `tls.key` から PFX を作り直す段階で失敗する:

```
E secrets_handlers.go:76] Code="ErrorExportingWithOpenSSL"
  Message="unable to export using openssl, error=[exit status 1],
           stderr=[No cert in -in file '/tmp/appgw-ingress-cert...' matches private key]"
```

（`openssl pkcs12 -export` は `-in` の**先頭の証明書**が秘密鍵に対応している必要がある。
リーフが最後にあり、しかもヘッダ混入でパースできないため「対応する証明書が無い」となる。）

#### 対処: PFX を KV に「証明書オブジェクト」として import し直す

ASC のシークレット値がそのまま base64 PFX なので、`azurerm_key_vault_certificate` の
`certificate.contents` に**直接渡せる**（秘密鍵をディスクに書き出す必要がない）。

```hcl
# ASC が KV に置いたシークレット (値は base64 の PFX)
data "azurerm_key_vault_secret" "asc_pfx" {
  name         = var.cert_secret_name
  key_vault_id = data.azurerm_key_vault.cert.id
}

# 同じ PFX を「KV 証明書オブジェクト」として import (別名)
resource "azurerm_key_vault_certificate" "pem" {
  name         = "${var.cert_secret_name}-pem"
  key_vault_id = data.azurerm_key_vault.cert.id
  certificate {
    contents = data.azurerm_key_vault_secret.asc_pfx.value
    password = "" # ASC の PFX はパスワード空
  }
}
```

SecretProviderClass はこちら（`appgw-tls-cert-pem`）を `objectName` に指す。
`objectEncoding` / `objectFormat` は不要。プロバイダがネイティブに扱い、
**リーフ先頭・ヘッダ無しのクリーンな PEM** が得られる:

```
[1] CN = azure-app-service-cert-check.example.com   ← リーフが先頭 ✅
[2] GoDaddy TLS Intermediate CA DV - R1v1
[3] GoDaddy TLS Root CA - R1
[4] Go Daddy Root Certificate Authority - G2
```

#### ★トレードオフ: import はスナップショットで自動追従しない

App Service Certificate が更新されると元のシークレット `appgw-tls-cert` は自動更新されるが、
**import 済みの `appgw-tls-cert-pem` は追従しない**（`terraform apply` し直しが必要）。

方式A は AppGW が **versionless secret id** で KV を直接見るため自動追従する。
→ **これが「ASC を使うなら方式A」の最大の根拠。**

### 3-2. `Managed Identity Operator` は方式B では不要

方式B は **AppGW に UAI を付けない**（証明書は CSI → K8s Secret → AGIC がアップロード）。
AppGW の PUT ボディに UAI 参照が入らないので、2-1 の `LinkedAuthorizationFailed` は起きない。

### 3-3. その他

- **`objectType` は `secret`**（`certificate` だと公開鍵のみで秘密鍵が無く TLS に使えない）。
- **Pod が CSI ボリュームをマウントしないと K8s Secret が生成されない**。
- Secret と Ingress は同一 namespace。
- AppGW 側の ssl-cert は `keyVaultSecretId: null`（= **AGIC 所有**。方式A とはここが逆）。

---

## 4. 環境・Terraform 共通

### 4-1. ★AGIC の Helm リポジトリ（Blob）が公開停止済み

従来の手順にある `helm repo add` は **もう使えない**:

```
$ helm repo add application-gateway-kubernetes-ingress \
    https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
Error: looks like "..." is not a valid chart repository or cannot be reached:
failed to fetch .../index.yaml : 409 Public access is not permitted on this storage account.
```

→ **MCR の OCI レジストリ**を使う:

```bash
helm install agic \
  oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure \
  --version 1.9.11 --namespace kube-system \
  --set appgw.subscriptionId=$(terraform output -raw subscription_id) \
  --set armAuth.identityClientID=$(terraform output -raw agic_identity_client_id) \
  -f k8s/agic-values.yaml

# 利用可能バージョン
curl -s https://mcr.microsoft.com/v2/azure-application-gateway/charts/ingress-azure/tags/list
```

> release 名は **`agic` 固定**。federated credential の subject が
> `system:serviceaccount:kube-system:agic-sa-ingress-azure` に依存している。

### 4-2. ★`ignore_changes` の漏れが AGIC の設定を消しにいく

AGIC が AppGW に作るものを `lifecycle.ignore_changes` に挙げ漏れると、
**次に `terraform apply` した瞬間に Terraform がそれを削除しようとする**（AGIC が作り直すので奪い合う）。

実際に踏んだのは **`redirect_configuration`**。Ingress の `ssl-redirect: "true"` で AGIC が作る
HTTP→HTTPS リダイレクト設定が `ignore_changes` に無く、plan に「削除」として出た。

> **apply 後は必ず `terraform plan` で `No changes` を確認する。**
> 差分が残っていたら、それは「次の apply で壊れるもの」。

`ssl_certificate` の扱いは方式で逆になる:
- **方式A**: Terraform 所有（KV リンクを張るのが要点） → ignore **しない**
- **方式B**: AGIC 所有（K8s Secret からアップロード） → ignore **する**

### 4-3. Azure 側の正規化による恒久 diff（2 件）

apply 後も plan が `N to change` のままになる。config を Azure の実値に合わせて解消する。

| 対象 | Azure が返す実値 |
|---|---|
| subnet delegation の `actions` | `Microsoft.Network/virtualNetworks/subnets/join/action`（`.../subnets/action` と書くと毎回差分） |
| AKS `default_node_pool.upgrade_settings` | `max_surge = "10%"`（省略すると provider が消そうとして毎回差分） |

### 4-4. ★azurerm は destroy 時に KV オブジェクトを purge する（権限が無いと destroy が失敗）

方式B の destroy で踏んだ。AKS/AppGW/RG まで全部消えた**最後の 1 件**で失敗する:

```
Error: purging of Certificate "appgw-tls-cert-pem" (Key Vault "https://kv-appgwcert-xxxx.vault.azure.net"):
  StatusCode=403 Code="Forbidden"
  Message="The user, group or application ... does not have certificates purge permission
           on key vault 'kv-appgwcert-xxxx'"
```

**原因**: azurerm は destroy 時に KV オブジェクトを soft-delete するだけでなく、
**purge（完全削除）まで実行するのが既定**（`purge_soft_deleted_certificates_on_destroy = true`）。
purge には KV の `Purge` 権限が必要だが、`cert/` の access policy は
`Get/List/Create/Import/Update/Delete` しか与えていないため 403 になる。

**そもそも purge すべきでない**: この証明書は
**`cert/` が所有する KeyVault の中に作った import 済みコピー**であり、
`assign-agic-csi` の destroy が purge まで踏み込むのは越権。
soft-delete の保持期間（7 日）で自動的に purge される。

**対処**: `assign-agic-csi/versions.tf` の provider features で purge を無効化する。

```hcl
provider "azurerm" {
  features {
    key_vault {
      purge_soft_deleted_certificates_on_destroy = false
    }
  }
}
```

> **他人の KeyVault にオブジェクトを作る構成では、この設定を必ず入れる。**
> 入れないと destroy が最後の 1 件で失敗し、state に取り残される。
> （`Purge` 権限を足す手もあるが、他ディレクトリの KV に purge 権限を持たせる方が危険）

### 4-5. appgw-subnet に NSG は付けない

AppGW v2 のサブネットに NSG を付けると 80/443 の許可だけでは足りず、
**GatewayManager からの 65200-65535 inbound** や AzureLoadBalancer の許可が別途必要になり、
抜けると AppGW が Unhealthy になる。検証の本筋と無関係な失敗要因なので付けていない。

### 4-6. azurerm v4 の RP 自動登録

`skip_provider_registration` は廃止され、5 モードの `resource_provider_registrations`
（none / core / extended / all / legacy）になった。**各セットに含まれる RP の一覧は公式ドキュメントに無く、
provider のソース (`required.go`) が唯一の一次情報。** 1-4 のとおり
`Microsoft.CertificateRegistration` はどのセットにも含まれない。

---

## 5. デバッグの入口（症状 → 見る場所）

| 症状 | まず見るところ |
|---|---|
| 証明書が Issued にならない | `dig +short TXT <zone> @8.8.8.8` で **ルート `@`** に TXT があるか |
| **KV にシークレットが 1 つも現れない** | **KV 紐付け（子リソース）を作ったか**（1-8）。作れば `Initialized` の空シークレットが出る |
| Issued なのに KV シークレットが空（`CertificateState: Initialized`） | KV の access policy に **CertificateRegistration RP**（`f3c21649...`）があるか（1-3） |
| 自動更新したのに古い証明書が出る | **3 層のどこで切れているか**（1-10）。KV は新しいか？ AppGW は versionless id か？ |
| **Ingress が AppGW に反映されない** | **AGIC のログ**（`kubectl logs -n kube-system -l app=ingress-azure`） |
| 方式B で **K8s Secret が生成されない** | **CSI ドライバのログ**（`kubectl logs -n kube-system -l app=secrets-store-csi-driver -c secrets-store`） |
| HTTPS が Connection refused | AppGW の `provisioningState` が `Updating` でないか |
| KV の「証明書」タブに何も無い | 正常。**「シークレット」タブ**を見る（1-1） |

`tls.crt` の健全性チェック（方式B）:

```bash
# PEM ヘッダ混入（壊れている合図）— 何も出なければ OK
kubectl get secret appgw-tls-cert -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | grep -E "localKeyId|friendlyName"

# 1 枚目がリーフであること
kubectl get secret appgw-tls-cert -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject

# tls.key と tls.crt(1枚目) の modulus 一致
kubectl get secret appgw-tls-cert -o jsonpath='{.data.tls\.key}' | base64 -d \
  | openssl rsa -noout -modulus | openssl md5
kubectl get secret appgw-tls-cert -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -modulus | openssl md5
```

---

## 6. 検証結果（2026-07-12）

発行された証明書:

| 項目 | 値 |
|---|---|
| オーダー | `appgw-cert-order` (Standard) → `Issued` |
| Subject | `CN=azure-app-service-cert-check.example.com` |
| Issuer | `GoDaddy TLS Intermediate CA DV - R1v1` |
| SAN | 素のホスト名 + **`www.` 付き**の 2 件 |
| 有効期間 | 2026-07-12 → 2027-01-26 |
| SHA1 拇印 | `575ED27A24F7907FBB1FE60D0A80BD202FAAF183` |
| KV | `kv-appgwcert-xxxx` / secret `appgw-tls-cert`（PFX フルチェーン + 秘密鍵、パスワード空） |

両方式の公開 HTTPS 検証（**ローカル PC から `-k` なし・`--resolve` なし**）:

```
azure-app-service-cert-check.example.com       → <APPGW_PUBLIC_IP_A>  HTTP 200 verify=0   (方式A)
www.azure-app-service-cert-check.example.com   → <APPGW_PUBLIC_IP_B>    HTTP 200 verify=0   (方式B)
                                     どちらも fp=575ED27A24F7907FBB1FE60D0A80BD202FAAF183
```

チェーンは Go Daddy Root CA - G2 まで到達し `Verification: OK`。HTTP は 301 で HTTPS へリダイレクト。

> **SAN が 2 件あることを利用して、方式A は素のホスト名、方式B は `www.` 付きを使い、
> 同じ 1 枚の証明書で両方式を同時に公開検証している。**（A レコードの衝突を避けるため）

`-k` なしで verify が通ることを合格条件にしたため、
「KV の証明書が AppGW に正しくロードされ、**中間証明書まで含めて**提示されている」ことも同時に実証された
（チェーンが欠けていれば verify が落ちる）。

---

## 7. 一次情報

- [Manage App Service Certificates](https://learn.microsoft.com/azure/app-service/configure-ssl-app-service-certificate)
  — ドメイン検証（TXT は `@`）、KV への access policy、FAQ「なぜ KV に値が無いのか」
- [AppGW + Key Vault 証明書](https://learn.microsoft.com/azure/application-gateway/key-vault-certs)
  — `keyVaultSecretId` / UAI / 自動ローテーション
- [AGIC で TLS を扱う](https://learn.microsoft.com/azure/application-gateway/ingress-controller-expose-service-over-http-https)
- [Secrets Store CSI Driver (Azure KeyVault provider)](https://azure.github.io/secrets-store-csi-driver-provider-azure/docs/configurations/getting-certs-and-keys/)
  — `objectType` / `objectEncoding` / `objectFormat` / `secretObjects`
- [azurerm v4 upgrade guide](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/4.0-upgrade-guide)
  — `skip_provider_registration` → `resource_provider_registrations`
- [azurerm の RP 登録セット実体 (required.go)](https://github.com/hashicorp/terraform-provider-azurerm/blob/main/internal/resourceproviders/required.go)
  — どのセットに何が含まれるかの唯一の一次情報

---

## 8. 後始末の注意

- **App Service Certificate の削除は取り消し不可（証明書が失効する）。** 有料リソースなので
  `cert/` の `terraform destroy` は意図を確認してから。
- **削除ロックをかけてある**（`cert/locks.tf`）:
  | ロック名 | 対象 | 理由 |
  |---|---|---|
  | `AppServiceCertificateLock` | KeyVault | 証明書の実体はここにしか無い（1-8） |
  | `CertOrderDoNotDelete` | 証明書オーダー | 削除 = 失効・取り消し不可 |

  ただし **`terraform destroy` は止められない**（ロック → 対象の順に消すため）。
  Terraform の外からの誤削除を防ぐだけ。確実に守るなら CLI 運用に切り替える（1-13）。
- KV は soft-delete 有効（7 日）。同名 KV を作り直す場合は purge が必要
  （`az keyvault purge -n <kv> --location <loc>`）。
- `assign-*` は AKS / AppGW が課金対象。検証が済んだら destroy してよい
  （証明書は `cert/` 側に残るので再構築できる）。
- **方式B の `appgw-tls-cert-pem`**（import した KV 証明書オブジェクト）は
  `assign-agic-csi` の destroy で消える。元の `appgw-tls-cert` には影響しない。
