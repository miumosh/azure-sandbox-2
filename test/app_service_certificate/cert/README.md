# cert/ — 証明書の検証（KeyVault 格納まで）

証明書を KeyVault に用意し、割り当て側 (assign-*) が `data` 参照するための出力を公開する。
`cert_source` で 2 モードを切り替える。

| cert_source | 内容 | 料金 | ドメイン検証 |
|---|---|---|---|
| `self_signed` (既定) | 自己署名を KV に作成 | 無料・即時 | 不要 |
| `app_service_order` | App Service Certificate 購入 + ARM で KV 紐付け | 有料(~$69/年) | 必要 |

どちらのモードでも **同名の KV シークレット (`key_vault_secret_name`, 既定 `appgw-tls-cert`)** を
生成するので、assign-* 側はモードを意識せず同じ `data` 参照で動く
（ただし方式B は例外。→ [`../findings.md` 3-1](../findings.md)）。

> 本 README は **cert/ の Terraform 手順とハマりどころ**。
> - **az CLI で運用する場合** → [`az_cli_pattern.md`](az_cli_pattern.md)
>   （**証明書は Terraform 管理に向かない**という結論もそこに整理）
> - 検証全体の知見（エラー全文・原因・デバッグ手順・一次情報） → [`../findings.md`](../findings.md)
> - 方式A/B の設計比較 → [`../keyvault_cert_using_pattern.md`](../keyvault_cert_using_pattern.md)

## ⚠️ 証明書オーダーは Terraform 管理に向かない

削除が**不可逆（証明書の失効）**、有料の一点物、KV 紐付けが azurerm 未対応（ARM 直書きが必要）、
恒久 diff、状態が Azure 側で勝手に遷移する — と、Terraform と噛み合わない条件が揃っている。

**推奨は「証明書オーダーだけ az CLI、周辺（KV/DNS/assign-\*）は Terraform」のハイブリッド。**
`assign-*` は KV を `data` 参照するだけなので、**cert/ を CLI 運用に替えても assign-\* は無改変**。
→ [`az_cli_pattern.md`](az_cli_pattern.md) / [`../findings.md` 1-13](../findings.md)

## 使い方

```bash
cp terraform.tfvars.example terraform.tfvars   # 編集
terraform init && terraform apply
terraform output                               # kv_name / secret_name / versionless_id を確認
```

### self_signed
apply しきりで完了。すぐに assign-* の配管検証に進める。

### app_service_order

```bash
# 1. RP 登録 (これをやらないと SP がテナントに生えず object id が引けない)
az provider register -n Microsoft.CertificateRegistration --wait

# 2. 2 つの RP の object id を取得して tfvars へ
az ad sp show --id f3c21649-0979-4721-ac85-b0216b2cf413 --query id -o tsv  # ★KV に書き込む主体
az ad sp show --id abfa0a7c-a6b6-4736-8310-5855508787cd --query id -o tsv  # App Service RP (任意)

# 3. apply → オーダー作成 + KV 紐付け + ルート @ に検証 TXT 投入
terraform apply

# 4. TXT が公開伝播していれば GoDaddy が自動検出し、数分で Issued になる
dig +short TXT example.com @8.8.8.8
az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-appgw-cert-test/providers/Microsoft.CertificateRegistration/certificateOrders/appgw-cert-order?api-version=2023-12-01" \
  --query "properties.status" -o tsv
# → Issued

# 自動検出されない場合だけ明示的に検証をキック
# az rest --method post --url ".../certificateOrders/appgw-cert-order/verifyDomainOwnership?api-version=2023-12-01"
```

## ハマりどころ（実検証で踏んだもの）

### 1. 検証 TXT は「ルートドメイン `@`」に置く（サブドメインではない）
CN が `azure-app-service-cert-check.example.com` でも、TXT はサブドメイン側ではなく
**ゾーンのルート `@`** に置く。公式ドキュメント (Manual verification) の原文:

> For domain verification via DNS TXT record for either the root domain (for example, `contoso.com`)
> or the subdomain (for example, `www.contoso.com` or `test.api.contoso.com`) and **regardless of the
> certificate SKU, you need to add a TXT record at the root domain level. Use `@` for the name** and
> the domain verification token for the value in your DNS record.

### 2. KV に書き込むのは CertificateRegistration RP（App Service RP ではない）
ポータルで作ると KV に access policy が **2 つ** 付く。証明書の実体 (PFX) を書き込むのは前者。

| RP | appId | 役割 |
|---|---|---|
| `Microsoft.Azure.CertificateRegistration` | `f3c21649-0979-4721-ac85-b0216b2cf413` | ★KV に PFX を書き込む主体 |
| `Microsoft Azure App Service` | `abfa0a7c-a6b6-4736-8310-5855508787cd` | KV から証明書を読む側 |

App Service RP だけを許可しても、Issued になった後も KV シークレットは空
(`CertificateState: Initialize`) のまま値が入らない。

なお **RP を登録するまで SP はテナントに存在しない**ため、object id を引く前に
`az provider register -n Microsoft.CertificateRegistration --wait` が必要。

### 3. `Microsoft.CertificateRegistration` は provider の自動登録セットに含まれない
azurerm v4 の `resource_provider_registrations` の legacy/core/extended/all の
**どのセットにも入っていない**（`providers.tf` のコメント参照）。
`resource_providers_to_register` で明示登録するか、上記 az コマンドで先に登録する。

### 4. KV には「シークレット」だけができ、「証明書オブジェクト」はできない
`az keyvault certificate show` は `CertificateNotFound` になる。実体は
`contentType: application/x-pkcs12` のシークレットとして入る（タグ `CertificateState: Ready`）。

→ 参照側は必ず **secret** として読むこと。
   - AppGW: `ssl_certificate.key_vault_secret_id` にシークレットの versionless id（OK）
   - CSI: SecretProviderClass の `objectType: secret`（`certificate` だと公開鍵のみで TLS に使えない）

self_signed モードは証明書オブジェクトも作るのでここが両モードの唯一の非対称点だが、
assign-* 側はどちらも secret 参照なので**無改変で切り替わる**。

### 5. 有効期間は「1 年」ではない
`validity_in_years = 1` で発注しても、実際に発行された証明書は
2026-07-12 → **2027-01-26**（約 6.5 ヶ月）だった。GoDaddy 側の発行ポリシーに従う。

### 6. ポータルのどこを見れば証明書を確認できるか
KeyVault 連携の証明書は **AppGW 側では中身が見えない**。AppGW の `sslCertificates` リソースが
持っているのは「参照」だけで、Subject も有効期限も拇印も入っていない:

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
| KV の実体（拇印・シリアル・状態） | Key Vault → **シークレット** → `appgw-tls-cert` のタグ |

> Key Vault では **「証明書」タブではなく「シークレット」タブ**を見ること。
> App Service Certificate は KV 証明書オブジェクトを作らないので「証明書」タブは空で、
> 探して「無い！」となりがち（上記 4. と同じ話）。

拇印は KV シークレットのタグ (`Thumbprint`) と、実際にエンドポイントが提示する証明書で一致する:
```bash
echo | openssl s_client -connect <fqdn>:443 -servername <fqdn> 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha1
```

### 7. `validity_in_years` が恒久 diff になる
発行後、API は `validity_in_years` に **0** を返す。config の `1` と食い違うため、
apply 済みでも plan が毎回 `1 to change` になる。有料オーダーに PATCH を打ちたくないので
`lifecycle { ignore_changes = [validity_in_years] }` で抑止している（`cert_order.tf`）。

### 8. CAA レコード
ゾーンに CAA がある場合は GoDaddy を明示許可する必要がある（`0 issue godaddy.com`）。
CAA 未設定のゾーンなら不要。

## 検証結果（2026-07-12 実施）

`cert_source = "app_service_order"` / `example.com` (rg-dns) で実施し、**成功**。

| 項目 | 結果 |
|---|---|
| オーダー | `appgw-cert-order` (Standard) → `Issued` |
| Subject | `CN=azure-app-service-cert-check.example.com` |
| Issuer | `GoDaddy TLS Intermediate CA DV - R1v1` |
| SAN | 当該 FQDN + `www.` 付きの 2 件 |
| KV | `kv-appgwcert-xxxx` / secret `appgw-tls-cert` (PFX フルチェーン + 秘密鍵、パスワード空) |

TXT 投入後、`verifyDomainOwnership` を叩くまでもなく CA が自動検出して Issued になった。

## 出力 (assign-* に渡す)

| output | 用途 |
|---|---|
| `key_vault_name` / `key_vault_resource_group` | assign-* の `data "azurerm_key_vault"` に渡す |
| `certificate_secret_name` | シークレット/証明書名 |
| `certificate_secret_versionless_id` | AppGW `ssl_certificate.key_vault_secret_id` にそのまま使える |

## 適用順序

**cert/ を apply（order の場合は Issued まで）してから assign-* を apply**。
assign-* は `data.azurerm_key_vault_secret` で plan 時に実体を読むため、
シークレットが存在しないと plan が失敗する。

## 後始末の注意

App Service Certificate の削除は**取り消し不可（証明書は失効する）**。有料リソースなので
`terraform destroy` は意図を確認してから。KV は soft-delete 有効（7 日）のため、
同名 KV を作り直す場合は purge が必要。
