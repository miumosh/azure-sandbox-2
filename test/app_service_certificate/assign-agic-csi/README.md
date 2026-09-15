# assign-agic-csi — 方式B: spec.tls + Secrets Store CSI Driver

`cert/` の KeyVault 証明書を **CSI ドライバで K8s TLS Secret に同期**し、Ingress の
`spec.tls.secretName` で参照する。AGIC はその Secret を読んで AppGW に証明書をアップロードする。
基盤は `aks/agic/helm/single_access_single_appgw` を土台にし、AKS に CSI アドオンを追加している。

## この方式の要点
- 秘密鍵が **K8s Secret (etcd) に materialize される**。
- AppGW の ssl_certificate は AGIC が動的に作る (KeyVault 非リンク) → appgw.tf の ignore_changes で除外済み。
- ローテーションは CSI(2m)→AGIC 再アップロードの 2 段。

> ## ⚠️ App Service Certificate では非推奨
> ASC は KV に「証明書オブジェクト」を作らないため、**この方式はそのままでは動かない**。
> KV への import を一段挟む必要があり（下記「ハマりどころ 1」）、その結果
> **ASC の更新に自動追従しなくなる**（= 方式B の売りである CSI 自動ローテーションが成立しない）。
> → ASC を使うなら [`../assign-appgw-direct/`](../assign-appgw-direct/)（方式A）が素直。
>
> 方式B が向くのは「KV 証明書オブジェクトを自前で管理している」ケース。

> 本 README は **方式B の手順とハマりどころ**。
> 検証全体の知見（エラー全文・原因・デバッグ手順・一次情報）は [`../findings.md`](../findings.md)、
> 方式A/B の設計比較は [`../keyvault_cert_using_pattern.md`](../keyvault_cert_using_pattern.md)。

## 検証経路: 公開 HTTPS（ローカル PC から）

方式A と同じく AppGW の **public frontend** を使い、ローカル PC から素の `curl` / ブラウザで検証する
（`-k` も `--resolve` も使わない）。テスト VM は撤去済み。

### ホスト名は「www 側の SAN」を使う — 方式A と同時に動かすため

方式A (`assign-appgw-direct`) が既に
`azure-app-service-cert-check.example.com` の A レコードを持っているため、
方式B が同じ名前を使うと**衝突する**。

一方、`cert/` が発行した証明書には SAN が **2 件**ある
（App Service Certificate の Standard SKU は `www.` 付きを自動で SAN に含める）:

| SAN | 使う方式 | A レコード |
|---|---|---|
| `azure-app-service-cert-check.example.com` | 方式A | → certdirect-appgw |
| `www.azure-app-service-cert-check.example.com` | **方式B** | → certcsi-appgw |

→ **同じ 1 枚の証明書のまま、方式A を消さずに両方式を同時に公開検証できる。**
TLS のホスト名不一致も起きない（SAN に含まれるため）。

一致必須なのは次の 3 つ（すべて `www.azure-app-service-cert-check.example.com`）:
証明書の SAN / `k8s/ingress.yaml` の `spec.tls.hosts` と `rules[].host` / `dns.tf` の A レコード。

## 前提
- `cert/` を apply 済み (KeyVault が存在すれば良い。証明書実体は CSI がランタイムに読む)。

## 手順
```bash
# 1) 基盤 + CSI アドオン + KeyVault アクセス許可 + DNS A レコードを apply
terraform -chdir=../cert output          # cert_kv_name / cert_kv_rg を確認
cp terraform.tfvars.sample terraform.tfvars   # 値を編集
terraform init && terraform apply

# 2) AGIC を Helm 導入 (MCR の OCI レジストリから)
#    ※ 旧 Helm リポジトリ https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/ は
#       公開停止済み (helm repo add が 409 "Public access is not permitted on this storage account")
$(terraform output -raw aks_get_credentials_cmd)
helm install agic \
  oci://mcr.microsoft.com/azure-application-gateway/charts/ingress-azure \
  --version 1.9.11 \
  --namespace kube-system \
  --set appgw.subscriptionId=$(terraform output -raw subscription_id) \
  --set armAuth.identityClientID=$(terraform output -raw agic_identity_client_id) \
  -f k8s/agic-values.yaml

# 3) SecretProviderClass を適用 (terraform output で <...> を埋める)
#    csi_identity_client_id / keyvault_name / tenant_id
terraform output
kubectl apply -f k8s/secretproviderclass.yaml

# 4) デモアプリ(CSIマウント) + Ingress(spec.tls)
kubectl apply -f k8s/ingress.yaml

# 5) CSI 同期の確認 (★方式B 固有の中間成果物)
kubectl get secretproviderclass appgw-tls-spc
kubectl get secret appgw-tls-cert -o jsonpath='{.type}'   # → kubernetes.io/tls
#   Pod が CSI ボリュームをマウントして初めて Secret が生成される点に注意
```

## 検証（ローカル PC から）
```bash
# 1) A レコード
dig +short A www.azure-app-service-cert-check.example.com @8.8.8.8
#    → terraform output appgw_public_ip と一致

# 2) ★本命: -k なし・--resolve なしの素の curl
curl -v $(terraform output -raw test_url)
#    期待: SSL certificate verify ok / HTTP 200

# 3) 提示証明書が cert/ の実体と一致するか (方式A と同じ 1 枚のはず)
openssl s_client -connect www.azure-app-service-cert-check.example.com:443 \
  -servername www.azure-app-service-cert-check.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -fingerprint -sha1
#    期待: 拇印が方式A / KV シークレットのタグ Thumbprint と一致
```

## ハマりどころ（実検証で踏んだもの）

### 1. ★App Service Certificate は CSI と素直に組み合わせられない（最大の落とし穴）

**症状**: Pod は `Running`。CSI マウントも成功。なのに **K8s Secret が生成されない**。
`kubectl get pod` も `kubectl get secretproviderclass` も正常に見えるので気づけない。
エラーは **CSI ドライバのログにしか出ない**:

```bash
kubectl logs -n kube-system -l app=secrets-store-csi-driver -c secrets-store
# E secretproviderclasspodstatus_controller.go:318] "failed to get data in spc for secret"
#   err="failed to get cert data from file .../appgw-tls-cert,
#        err: pkcs12: error reading P12 data: asn1: structure error: tags don't match ..."
```

**原因**: CSI の Azure プロバイダは **KV に「証明書オブジェクト」がある場合にだけ**
PKCS12 → PEM 変換をしてくれる。ところが App Service Certificate は
**KV 証明書オブジェクトを作らず、素のシークレットに base64 の PFX を入れるだけ**
（→ `cert/README.md` の「KV にはシークレットだけができ、証明書オブジェクトはできない」）。

素のシークレットを直接指すと、どう設定しても破綻する:

| 設定 | ファイルの中身 | 結果 |
|---|---|---|
| `objectEncoding` 無し（既定 utf-8） | base64 **文字列**のまま | ドライバの PKCS12 パースが asn1 エラー → **Secret が生成されない** |
| `objectEncoding: base64` | バイナリ PFX | Secret は生成されるが**中身が壊れている**（下記） |
| `objectFormat: pem` | バイナリ PFX | 同上（プロバイダは PEM 変換してくれない） |

バイナリ PFX になると **CSI ドライバ側**が PKCS12 を解釈する。すると Go の `pkcs12.ToPEM` が
**バッグ属性を PEM ヘッダとして出力**してしまい、`tls.crt` のリーフがこうなる:

```
-----BEGIN CERTIFICATE-----
localKeyId: 01000000          ← OpenSSL は Proc-Type 以外のヘッダを解釈できない

MIIHnjCCBYag...
```

さらに**チェーンが逆順**（ルートが先頭・リーフが最後）で出る。
結果、AGIC が `tls.crt` + `tls.key` から PFX を作り直す段階で失敗する:

```
Code="ErrorExportingWithOpenSSL"
Message="unable to export using openssl, ... stderr=[No cert in -in file
         '/tmp/appgw-ingress-cert...' matches private key]"
```

**対処**: 同じ PFX を **KV に「証明書オブジェクト」として import し直す**。
`cert_ref.tf` の `azurerm_key_vault_certificate.pem` がそれを行い、
SecretProviderClass はそちら（`appgw-tls-cert-pem`）を `objectName` に指す。
プロバイダがネイティブに扱うので、**リーフ先頭・ヘッダ無しのクリーンな PEM** が得られる。

ASC のシークレット値がそのまま base64 PFX なので、`azurerm_key_vault_certificate` の
`certificate.contents` に直接渡せる（**秘密鍵をディスクに書き出す必要がない**）:

```hcl
data "azurerm_key_vault_secret" "asc_pfx" { name = var.cert_secret_name, ... }

resource "azurerm_key_vault_certificate" "pem" {
  name         = "${var.cert_secret_name}-pem"
  key_vault_id = data.azurerm_key_vault.cert.id
  certificate {
    contents = data.azurerm_key_vault_secret.asc_pfx.value  # = base64 PFX
    password = ""
  }
}
```

#### ★トレードオフ: import はスナップショットで、自動追従しない
App Service Certificate が更新されると元のシークレット `appgw-tls-cert` は自動更新されるが、
**import 済みの `appgw-tls-cert-pem` は自動追従しない**（`terraform apply` し直しが必要）。

方式A は AppGW が **versionless secret id** で KV を直接見るため自動追従する。

> **結論: App Service Certificate を使うなら方式A（`assign-appgw-direct`）が素直。**
> 方式B は「KV に自前で管理する証明書オブジェクトがある」ケース向けであり、
> ASC と組み合わせると import 一段を挟むぶん、更新追従が壊れる。

### 2. 検証コマンド（デバッグの入口）
```bash
# Secret が生成されない → まず CSI ドライバのログ
kubectl logs -n kube-system -l app=secrets-store-csi-driver -c secrets-store --tail=50

# Ingress が AppGW に反映されない → AGIC のログ
kubectl logs -n kube-system -l app=ingress-azure --tail=50

# tls.crt の中身を厳密に検証（ヘッダ混入・並び順）
kubectl get secret appgw-tls-cert -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | grep -E "localKeyId|friendlyName"        # 何も出なければ OK
kubectl get secret appgw-tls-cert -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject             # 1 枚目がリーフであること
```

### 3. その他
- **objectType は secret**（`certificate` だと公開鍵のみで秘密鍵が無く TLS に使えない）。
- **Pod が CSI ボリュームをマウントしないと K8s Secret が生成されない**（ingress.yaml の Deployment に mount 済み）。
- Secret と Ingress は同一 namespace であること。
- CSI アドオン Identity への KeyVault Get 付与は cert_ref.tf で実施済み。
- **AGIC の Helm リポジトリ(Blob)は公開停止済み** → OCI (MCR) を使う。上記手順参照。
- `ignore_changes` に `redirect_configuration` を追加済み（漏れると次の apply で AGIC の
  HTTP→HTTPS リダイレクトを Terraform が消しにいく）。`ssl_certificate` は方式B では
  **AGIC 所有**なので ignore する（方式A とはここが逆）。

### 4. 方式A で必要だった `Managed Identity Operator` は方式B では不要
方式A は AppGW 本体に KeyVault 読み取り用の UserAssigned Identity を紐付けるため、
AGIC が AppGW を PUT する際にその UAI 参照がボディに入り、ARM が
`userAssignedIdentities/assign/action` を要求する
（無いと `LinkedAuthorizationFailed` で AGIC が AppGW を更新できない）。

方式B は **AppGW に UAI を付けない**（証明書は CSI → K8s Secret → AGIC がアップロード）ため、
この権限は不要。詳細は `../assign-appgw-direct/README.md` 参照。

## 検証結果（2026-07-12 実施・成功）

`cert/` の App Service Certificate を、上記の「KV 証明書オブジェクトへの import」を挟んで使用。
**ローカル PC から `-k` なし・`--resolve` なしの素の curl で HTTPS が通ることを確認**。

```
$ curl -sS -o /dev/null -w "HTTP %{http_code} | ssl_verify: %{ssl_verify_result}\n" \
    https://www.azure-app-service-cert-check.example.com
HTTP 200 | ssl_verify: 0

$ openssl s_client -connect www.azure-app-service-cert-check.example.com:443 ...
subject = CN = azure-app-service-cert-check.example.com
issuer  = GoDaddy TLS Intermediate CA DV - R1v1
sha1 Fingerprint = 57:5E:D2:7A:...:F1:83     ← 方式A / KV シークレットのタグと同一の 1 枚
Verification: OK

$ curl -sI http://www.azure-app-service-cert-check.example.com
HTTP 301 → https://...                       ← ssl-redirect
```

CSI が生成した K8s Secret も検証済み:
- `tls.crt`: 4 枚（**リーフ先頭** → Intermediate → Root R1 → Root G2）、PEM ヘッダ混入なし
- `tls.key`: `tls.crt` の 1 枚目と modulus 一致
- AppGW 側の ssl-cert は `keyVaultSecretId: null`（= **AGIC 所有**。方式A とはここが逆）

**方式A と同時稼働**している（証明書の SAN が 2 件あるため、方式A は素のホスト名、
方式B は `www.` 付きを使用。同じ 1 枚の証明書で両方式が公開検証できている）。
