# cert/ — az CLI で証明書を用意するパターン（Terraform を使わない選択肢）

App Service Certificate（購入証明書）を **Terraform で管理しない**場合の手順。
[`README.md`](README.md) の Terraform 版と**同じ結果**（KeyVault に `appgw-tls-cert` シークレット）になる。
割り当て側（`assign-*`）は KV を `data` 参照するだけなので、**cert/ を CLI 運用に切り替えても assign-* は無改変**。

---

## なぜ Terraform で管理しない選択肢があるのか

証明書は「Terraform で管理して嬉しいリソース」の条件から外れている。

| 観点 | 実情 |
|---|---|
| **destroy が破壊的で不可逆** | App Service Certificate の削除は**証明書の失効**を意味する。取り消せない。`terraform destroy` の巻き添えで消えると復旧できない |
| **有料・一点物** | 誤って作り直すと再課金（~$69/年）。Terraform の「壊して作り直す」思想と噛み合わない |
| **azurerm にネイティブリソースが無い** | KeyVault 紐付け（`certificateOrders/certificates`）は azurerm 未対応。**ARM テンプレートデプロイで代替**する羽目になる（= 結局 ARM を書く） |
| **恒久 diff** | 発行後 API が `validity_in_years: 0` を返すため plan が毎回汚れる。`ignore_changes` が必要 |
| **ライフサイクルが極端に長い** | 作るのは 1 回、あとは年 1 回の更新だけ。頻繁に apply する対象ではない |
| **状態が Azure 側で勝手に変わる** | Pending → Issued、更新による新バージョン発行など、Terraform の管理外で状態遷移する |

一方で **KeyVault や DNS ゾーンは Terraform 管理が向く**（冪等・再作成可能・destroy が怖くない）。

> **推奨: 「証明書オーダーだけ CLI、周辺（KV/DNS）は Terraform」というハイブリッド。**
> 本ドキュメントは全部 CLI で通す手順を書くが、KV/DNS 部分は Terraform に寄せてもよい。

---

## ★前提知識: az CLI に「証明書を購入する」コマンドは無い

```bash
$ az appservice --help
Subgroups:
    ase / domain / hybrid-connection / plan / vnet-integration   # ← certificate は無い

$ az webapp config ssl --help
    import : Import an SSL or App Service Certificate to a web app from Key Vault.
             # ← "既にある ASC を Web App に取り込む" だけ。購入はできない
```

つまり **ARM API を直接叩く**しかない（`az rest` / `az resource`）。
扱うリソースタイプは 2 つ:

| リソースタイプ | 役割 |
|---|---|
| `Microsoft.CertificateRegistration/certificateOrders` | 証明書オーダー本体（購入） |
| `Microsoft.CertificateRegistration/certificateOrders/certificates` | **KeyVault 紐付け**（子リソース） |

後者が「ポータルの証明書の構成 → 手順1: 保存(Store)」の正体。
**明示的に作らないと証明書は KeyVault に入らない**（→ [`../findings.md` 1-10](../findings.md)）。

---

## 手順

### 0. 変数

```bash
SUB=$(az account show --query id -o tsv)
RG=rg-appgw-cert-test
LOC=japaneast
KV=kv-appgwcert-xxxx            # グローバル一意
ORDER=appgw-cert-order
SECRET=appgw-tls-cert           # KV シークレット名 = AppGW/AGIC 側の証明書名
CN=azure-app-service-cert-check.example.com
DNS_ZONE=example.com
DNS_RG=rg-dns
API=2023-12-01
```

### 1. リソースプロバイダを登録

**これをやらないと SP がテナントに生えず、次の手順で object id が引けない。**

```bash
az provider register -n Microsoft.CertificateRegistration --wait
az provider show -n Microsoft.CertificateRegistration --query registrationState -o tsv   # → Registered
```

### 2. RG と KeyVault を作成

```bash
az group create -n $RG -l $LOC

# access policy モード（RBAC ではなく）で作る
az keyvault create -n $KV -g $RG -l $LOC \
  --enable-rbac-authorization false \
  --retention-days 7
```

### 3. KeyVault に 2 つの RP を許可

**★最重要。ここを間違えると Issued になっても KV が空のままになる。**

| RP | appId | 役割 |
|---|---|---|
| `Microsoft.Azure.CertificateRegistration` | `f3c21649-0979-4721-ac85-b0216b2cf413` | ★**KV に PFX を書き込む主体** |
| `Microsoft Azure App Service` | `abfa0a7c-a6b6-4736-8310-5855508787cd` | KV から証明書を読む側 |

```bash
CERTREG_OID=$(az ad sp show --id f3c21649-0979-4721-ac85-b0216b2cf413 --query id -o tsv)
APPSVC_OID=$(az ad sp show --id abfa0a7c-a6b6-4736-8310-5855508787cd --query id -o tsv)

# ★これが本命（証明書を KV に書き込む）
az keyvault set-policy -n $KV --object-id $CERTREG_OID --secret-permissions get list set delete

# ポータル作成時と同じ状態に揃える（任意）
az keyvault set-policy -n $KV --object-id $APPSVC_OID --secret-permissions get list set delete

# 実行者自身（確認用）
ME_OID=$(az ad signed-in-user show --query id -o tsv)
az keyvault set-policy -n $KV --object-id $ME_OID --secret-permissions get list set delete
```

> 証明書は KV に**シークレット (PFX)** として入るので `--secret-permissions` が本質。
> 公式ドキュメントの表は certificate 側にも "Set" と書いているが、
> **KV の certificate 権限に `Set` は存在しない**ので付けなくてよい。

### 4. 証明書オーダーを作成（★ここから課金）

```bash
az rest --method put \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER?api-version=$API" \
  --body "{
    \"location\": \"global\",
    \"properties\": {
      \"distinguishedName\": \"CN=$CN\",
      \"productType\": \"StandardDomainValidatedSsl\",
      \"validityInYears\": 1,
      \"keySize\": 2048,
      \"autoRenew\": false
    }
  }"
```

| プロパティ | 値 | 備考 |
|---|---|---|
| `location` | **`global`** 固定 | リージョンを指定すると失敗する |
| `productType` | `StandardDomainValidatedSsl` | ワイルドカードは `StandardDomainValidatedWildCardSsl`。<br>（Terraform の `product_type = "Standard"` はこれにマップされる） |
| `autoRenew` | `false` / `true` | `true` にすると期限32日前から**自動更新（課金）** |

状態確認:
```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER?api-version=$API" \
  --query "{status:status,token:properties.domainVerificationToken}" -o json
# → status: "PendingIssuance"
```

### 5. ★KeyVault に紐付ける（これをしないと証明書が入らない）

**検証より前にやる。** ポータルが「手順1: 保存 → 手順2: 検証」の順を強制するのと同じ理由で、
紐付けが無いと発行された証明書の行き場が無い。

```bash
KV_ID=$(az keyvault show -n $KV -g $RG --query id -o tsv)

az rest --method put \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER/certificates/$SECRET?api-version=$API" \
  --body "{
    \"location\": \"global\",
    \"properties\": {
      \"keyVaultId\": \"$KV_ID\",
      \"keyVaultSecretName\": \"$SECRET\"
    }
  }"
```

**紐付けが成功した確認**（＝ 権限が正しいことの証明）:
```bash
az keyvault secret show --vault-name $KV -n $SECRET --query tags -o json
# → { "CertificateState": "Initialized" }   ← 値はまだ空のプレースホルダ
```

> ここで **`Initialized` の空シークレットが現れれば、紐付けと RP 権限は正しい。**
> 現れない / エラーになるなら手順 3 を疑う。

### 6. DNS TXT で所有権を検証

**★TXT は「ルートドメイン `@`」に置く。** CN がサブドメインでも同じ。

```bash
TOKEN=$(az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER?api-version=$API" \
  --query "properties.domainVerificationToken" -o tsv)

az network dns record-set txt add-record \
  -g $DNS_RG -z $DNS_ZONE -n "@" --value "$TOKEN"

# 公開伝播を確認
dig +short TXT $DNS_ZONE @8.8.8.8
```

伝播していれば **GoDaddy が自動検出**し、数分で Issued になる。

```bash
watch -n 30 "az rest --method get \
  --url 'https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER?api-version=$API' \
  --query 'properties.status' -o tsv"
# → Issued
```

自動検出されない場合だけ、明示的に検証をキックする:
```bash
az rest --method post \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER/verifyDomainOwnership?api-version=$API"
# 既に検証済みだと CertificateResellerWebService_INVALID_STATE
#   "This request is no longer Pending Validation" が返る（= 成功しているサイン）
```

### 7. KeyVault に実体が入ったことを確認

```bash
az keyvault secret show --vault-name $KV -n $SECRET --query "{contentType:contentType,tags:tags}" -o json
# → contentType: "application/x-pkcs12"
#    tags: { "CertificateState": "Ready", "Thumbprint": "575ED2...", "SerialNumber": "..." }
```

中身の検証（PFX はパスワード空）:
```bash
az keyvault secret download --file /tmp/asc.pfx --vault-name $KV -n $SECRET --encoding base64
openssl pkcs12 -in /tmp/asc.pfx -passin pass: -nokeys -clcerts 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
rm -f /tmp/asc.pfx     # ★秘密鍵入りなので必ず消す
```

> `az keyvault certificate show` は **`CertificateNotFound` になるのが正常**。
> App Service Certificate は KV に「証明書オブジェクト」を作らない（→ [`../findings.md` 1-1](../findings.md)）。

### 8. ★削除ロックをかける（CLI 運用では特に重要）

**ポータルで作ると KV に `AppServiceCertificateLock` という削除ロックが自動で付くが、
ARM API / Terraform 経由では付かない。** 証明書の実体は KV にしか無いので、
KV を誤削除すると証明書を取り出す手段が消える。

```bash
# KeyVault（証明書の実体の置き場）
az lock create --name AppServiceCertificateLock --lock-type CanNotDelete \
  --resource-group $RG --resource-name $KV \
  --resource-type Microsoft.KeyVault/vaults

# 証明書オーダー（削除 = 失効。取り消し不可）
az lock create --name CertOrderDoNotDelete --lock-type CanNotDelete \
  --resource-group $RG --resource-name $ORDER \
  --namespace Microsoft.CertificateRegistration --resource-type certificateOrders

az lock list -g $RG -o table
```

### 9. assign-* に渡す値

```bash
echo "cert_kv_name     = \"$KV\""
echo "cert_kv_rg       = \"$RG\""
echo "cert_secret_name = \"$SECRET\""

# AppGW の ssl_certificate.key_vault_secret_id に渡す versionless id
echo "versionless_id   = $(az keyvault show -n $KV -g $RG --query properties.vaultUri -o tsv)secrets/$SECRET"
```

`assign-appgw-direct` / `assign-agic-csi` の `terraform.tfvars` にそのまま貼る。

---

## 更新（自動更新の設定）

**自動更新は 3 層の連鎖**。混同しやすいので分けて理解する。

| # | 何が自動か | 設定方法 | 備考 |
|---|---|---|---|
| 1 | **CA が証明書を再発行** | オーダーの `autoRenew` | 期限32日前から。**課金発生** |
| 2 | **KV シークレットに新バージョンが書かれる** | 設定不要 | 紐付け（手順5）と RP 権限（手順3）が生きていれば RP が自動でやる |
| 3 | **AppGW が新バージョンを拾う** | AppGW 側で **versionless id** を使う | ~4h ポーリング。方式A のみ |

`autoRenew` の切り替え:
```bash
az rest --method patch \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER?api-version=$API" \
  --body '{"properties":{"autoRenew":true}}'

# 確認（true なら nextAutoRenewalTimeStamp に日時が入る）
az rest --method get \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER?api-version=$API" \
  --query "properties.{autoRenew:autoRenew,next:nextAutoRenewalTimeStamp,expiry:expirationTime}" -o json
```

手動更新:
```bash
az rest --method post \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER/renew?api-version=$API" \
  --body '{"keySize":2048,"delayExistingRevokeInHours":0}'
```

> **⚠️ 購入証明書はドメインの自動再検証をしない。**
> 前回検証から **395 日**以上経っていると更新時に再検証が必要になり、放置すると更新が失敗する
> （無料の App Service Managed Certificate とはここが違う）。
> **手順 6 で作ったルートの TXT レコードは消さない方が安全。**

---

## 削除（★取り消し不可）

**App Service Certificate の削除は証明書の失効を意味する。取り消せない。**

```bash
# ロックを外さないと消せない（それが狙い）
az lock delete --name CertOrderDoNotDelete -g $RG \
  --resource-name $ORDER --namespace Microsoft.CertificateRegistration --resource-type certificateOrders

az rest --method delete \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CertificateRegistration/certificateOrders/$ORDER?api-version=$API"
```

KV は soft-delete 有効（7 日）。同名 KV を作り直す場合は purge が必要:
```bash
az keyvault purge -n $KV --location $LOC
```

---

## Terraform 版との対応表

| 手順 | CLI | Terraform (`cert/`) |
|---|---|---|
| RP 登録 | `az provider register` | `providers.tf` の `resource_providers_to_register` |
| KV | `az keyvault create` | `keyvault.tf` の `azurerm_key_vault` |
| RP への KV 許可 | `az keyvault set-policy` ×2 | `azurerm_key_vault_access_policy`（certificate_registration_rp / appservice_rp） |
| オーダー | `az rest put .../certificateOrders/...` | `azurerm_app_service_certificate_order` |
| **KV 紐付け** | `az rest put .../certificates/...` | **`azurerm_resource_group_template_deployment`**（azurerm 未対応のため ARM 直書き） |
| DNS TXT | `az network dns record-set txt add-record` | `azurerm_dns_txt_record` |
| 削除ロック | `az lock create` | `azurerm_management_lock`（`locks.tf`） |
| 自動更新 | `autoRenew` プロパティ | `auto_renew` 引数 |

---

## 参考

- 罠と原因の詳細: [`../findings.md`](../findings.md)
- Terraform 版の手順: [`README.md`](README.md)
- [Manage App Service Certificates](https://learn.microsoft.com/azure/app-service/configure-ssl-app-service-certificate)
- [Certificate Orders REST API](https://learn.microsoft.com/rest/api/appservice/app-service-certificate-orders)
