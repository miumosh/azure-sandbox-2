# KeyVault 証明書を AppGW/AGIC で使う 2 方式の比較

App Service Certificate（購入証明書）を KeyVault に格納した状態から、
Application Gateway + AGIC（Helm）で TLS 終端に使う方法は大きく 2 通りある。

- **方式 A: AppGW → KeyVault 直参照**（Ingress アノテーション `appgw-ssl-certificate`）
- **方式 B: `spec.tls.secretName` + Secrets Store CSI Driver**

両者は「見た目の設定場所」だけでなく、**証明書の実体がどこに置かれ、誰が AppGW に載せ、
どうローテーションするか**という構造がまったく異なる。以下で詳細に比較する。

> **本ドキュメントは設計比較。実検証で踏んだ罠・エラー全文・対処は
> [`findings.md`](findings.md) にまとめている。**
>
> **結論を先に言うと: App Service Certificate を使うなら方式 A が素直。**
> 方式 B は動くが、下記 0 の性質により **KV への import を一段挟む必要があり、
> その結果として証明書更新への自動追従が失われる**（→ [findings.md 3-1](findings.md)）。

---

## 0. 共通の前提: App Service Certificate の KeyVault 格納形態

> ⚠️ **実検証で判明（当初の想定は誤りだった）**

- App Service Certificate は KeyVault に **PFX（秘密鍵込み・エクスポート可能）** として格納される。
- ただし **KeyVault 上に「証明書オブジェクト」は作られない。**
  作られるのは **素のシークレット 1 個だけ**で、その**値が base64 エンコードされた PFX**。

  ```bash
  $ az keyvault certificate show --vault-name <kv> -n appgw-tls-cert
  ERROR: (CertificateNotFound) ...        # ← 証明書オブジェクトは存在しない

  $ az keyvault secret show --vault-name <kv> -n appgw-tls-cert --query contentType
  "application/x-pkcs12"                  # ← シークレットとしてだけ存在する
  ```

- したがって参照側は **必ず secret として読む**:
  - AppGW: `ssl_certificate.key_vault_secret_id`（= シークレットの versionless id）
  - CSI: `objectType: secret`（`certificate` だと公開鍵のみで秘密鍵が無く TLS に使えない）

- **この性質が方式 B の成否を分ける。** CSI の Azure プロバイダは
  「KV 証明書オブジェクトがある場合にだけ」PKCS12 → PEM 変換をするため、
  ASC のシークレットを直接指すと **どう設定しても壊れる**（→ 2 章の注意書き / findings.md 3-1）。

- なお `self_signed` モード（cert/ の検証用）は KV 証明書オブジェクトも作る。
  **両モードの唯一の非対称点**であり、方式 B ではここが効いてくる。

---

## 1. 方式 A: AppGW → KeyVault 直参照（アノテーション方式）

### 概要
AppGW リソース自身に `ssl_certificate { key_vault_secret_id = ... }` を定義し、
**AppGW が KeyVault を直接参照**する。AGIC はその証明書を「名前」で参照するだけで、
証明書の実体・秘密鍵には一切触れない。

### アーキテクチャ
```
 KeyVault (PFX)
     ▲  keyVaultSecretId 参照 + 定期ポーリング(約4h)で新バージョン追従
     │
 Application Gateway
   ├─ identity: UserAssigned MI  ── Get 権限 ─▶ KeyVault
   └─ ssl_certificate "appgw-tls-cert" (Terraform 所有)
     ▲  名前 "appgw-tls-cert" で参照するだけ
     │
 AGIC (Helm)  ◀── Ingress annotation: appgw-ssl-certificate: appgw-tls-cert
```

### 詳細フロー
1. Terraform が AppGW に `ssl_certificate`（KeyVault リンク）と UserAssigned MI を定義。
2. AppGW の MI が KeyVault から証明書を pull し、AppGW 内部にロード。
3. AGIC は Ingress のアノテーションを見て、**HTTPS リスナーを作り既存の名前付き証明書を割り当てる**。
4. KeyVault 側で証明書が更新されると、AppGW が **versionless secret id 経由で自動追従**（約 4 時間間隔でポーリング）。

### 必要コンポーネント / リソース
| レイヤ | 必要なもの |
|---|---|
| KeyVault | 証明書 + AppGW MI への Get アクセス（アクセスポリシー or RBAC） |
| AppGW | `identity{}`(UserAssigned) + `ssl_certificate{ key_vault_secret_id }` |
| AKS/AGIC | AGIC(Helm) のみ。追加アドオン不要 |
| Ingress | アノテーション `appgw-ssl-certificate`。**`spec.tls` は書かない** |

### ローテーション
- **AppGW ネイティブ**。versionless secret id を使えば KeyVault の新バージョンを
  自動検知（約 4h）。K8s 側の操作は不要。

### セキュリティ
- 秘密鍵は **KeyVault と AppGW の中だけ**。Kubernetes クラスタ（etcd）に秘密鍵が出ない。
- 権限は「AppGW MI → KeyVault Get」のみ。攻撃面が小さい。

---

## 2. 方式 B: `spec.tls.secretName` + Secrets Store CSI Driver

### 概要
`spec.tls.secretName` が参照できるのは **KeyVault ではなく Kubernetes Secret**。
そこで Secrets Store CSI Driver（Azure KeyVault プロバイダ）で
**KeyVault 証明書 → K8s TLS Secret に同期**し、それを Ingress の `spec.tls` で参照する。
AGIC は K8s Secret の中身（証明書＋秘密鍵）を読み、**自分で AppGW にアップロード**する。

### アーキテクチャ
```
 KeyVault (PFX)
     ▲  Get (objectType: secret)
     │
 Secrets Store CSI Driver (AKS addon) + SecretProviderClass
   └─ Pod がボリュームマウント ─▶ K8s Secret "appgw-tls-cert" (kubernetes.io/tls, 秘密鍵込み)
     ▲  spec.tls.secretName で参照
     │
 AGIC (Helm)  ── K8s Secret を読み、証明書データを AppGW にアップロード
     │
 Application Gateway
   └─ ssl_certificate (AGIC 所有 / KeyVault 非リンクの "データ" 証明書)
```

### 詳細フロー
1. AKS の CSI アドオン（`key_vault_secrets_provider`）を有効化。アドオン用 MI が作られる。
2. `SecretProviderClass` で KeyVault 証明書を `objectType: secret`（PFX）として指定し、
   `secretObjects` で `kubernetes.io/tls` の K8s Secret を生成するよう定義。
3. **CSI ボリュームをマウントする Pod が起動して初めて** K8s Secret が同期・生成される。
4. Ingress の `spec.tls.secretName` がその Secret を指す。
5. AGIC が Secret（tls.crt/tls.key）を読み、AppGW に ssl_certificate として **アップロード**。

### ⚠️ App Service Certificate では「そのままでは動かない」

上記フローの 2〜3 が **ASC では破綻する**。0 章のとおり ASC は KV 証明書オブジェクトを作らないため、
CSI の Azure プロバイダが PKCS12 → PEM 変換をしてくれない。代わりに CSI ドライバ側が PKCS12 を
解釈することになり、`tls.crt` に `localKeyId` ヘッダが混入 + チェーン逆順（リーフが最後）になって、
AGIC の `openssl pkcs12 -export` が `No cert in -in file matches private key` で失敗する。

しかも **既定設定では K8s Secret が黙って生成されない**（Pod は Running のまま）ため、
気づくには CSI ドライバのログを見るしかない。

**対処**: 同じ PFX を **KV に「証明書オブジェクト」として import し直し**、
SecretProviderClass はそちらを指す（`assign-agic-csi/cert_ref.tf` の
`azurerm_key_vault_certificate.pem`）。ASC のシークレット値がそのまま base64 PFX なので、
`certificate.contents` に直接渡せる（秘密鍵をディスクに出さずに済む）。

**代償**: import は**スナップショットのコピー**。ASC が更新されても
**自動追従しない**（`terraform apply` し直しが必要）。
→ エラー全文・詳細は [findings.md 3-1](findings.md)。

### 必要コンポーネント / リソース
| レイヤ | 必要なもの |
|---|---|
| KeyVault | 証明書 + **CSI アドオン MI** への Get アクセス |
| AKS | `key_vault_secrets_provider{}` アドオン有効化（+ 任意で secret_rotation） |
| クラスタ内 | `SecretProviderClass` + **CSI ボリュームをマウントする Pod** |
| AGIC/Ingress | Ingress に `spec.tls.hosts/secretName`。アノテーション不要 |
| AppGW | **Terraform 側の ssl_certificate/identity は不要**（AGIC が作る） |

### ローテーション
- CSI のローテーションポーリング（`secret_rotation_enabled=true`、既定間隔 ~2 分）で
  K8s Secret を更新 → **AGIC が検知して AppGW に再アップロード**。
- AppGW は KeyVault を直接見ていないため、CSI と AGIC の 2 段を経由する。

### セキュリティ
- **秘密鍵が Kubernetes Secret（etcd）に materialize される**。クラスタ RBAC・etcd 暗号化・
  namespace 分離の設計が別途重要になる。
- 権限は「CSI アドオン MI → KeyVault Get」。

---

## 3. 詳細比較表

| 観点 | 方式 A: AppGW→KeyVault 直参照 | 方式 B: spec.tls + CSI |
|---|---|---|
| Ingress の書き方 | アノテーション `appgw-ssl-certificate` | `spec.tls.hosts/secretName` |
| AppGW の証明書 | KeyVault リンク（`keyVaultSecretId`） | AGIC がアップロードしたデータ（`keyVaultSecretId: null`） |
| 証明書実体の置き場所 | KeyVault / AppGW のみ | + **K8s Secret（秘密鍵込み）** |
| AppGW の ssl_certificate 所有者 | **Terraform**（→ `ignore_changes` しない） | **AGIC**（→ `ignore_changes` する） |
| Terraform の AppGW 差分 | 必要（identity + ssl_certificate） | 不要 |
| 追加の AKS アドオン | 不要 | **CSI Driver 必須** |
| クラスタ内追加リソース | なし | SecretProviderClass + マウント Pod |
| 必要な Azure 権限 | AppGW UAI → KV Get<br>**+ AGIC に `Managed Identity Operator`**（UAI スコープ）★ | CSI アドオン MI → KV Get のみ |
| **ASC を使う際の追加作業** | **なし** | **KV へ証明書オブジェクトとして import ★** |
| **ASC 更新への追従** | ✅ **自動**（versionless secret id, ~4h ポーリング） | ❌ **しない**（import がスナップショットのため） |
| 秘密鍵がクラスタに出るか | **出ない** | **出る（etcd）** |
| 適用順序の制約 | 証明書 Issued 後でないと AppGW 作成失敗<br>KV access policy への `depends_on` 必須 ★ | Pod マウントされないと Secret 未生成 |
| 主なハマりどころ | `LinkedAuthorizationFailed` ★<br>`ignore_changes` の漏れ | **ASC だと素直に動かない** ★<br>Secret が黙って生成されない |
| 証明書のソースオブトゥルース | KeyVault（一元管理しやすい） | KeyVault だが実体が K8s にも複製される |

★ = 実検証で踏んだ点。詳細は [`findings.md`](findings.md)。

---

## 4. メリット・デメリット整理

### 方式 A（AppGW→KeyVault 直参照）
**メリット**
- 秘密鍵がクラスタに出ず、セキュリティ境界が明確。
- ローテーションが AppGW ネイティブで単純（KeyVault を更新するだけ）。
- 追加アドオン不要、依存が少ない。
- KeyVault を証明書の単一の真実の源にできる。

**デメリット**
- AppGW 側（Terraform）に identity + ssl_certificate の実装が必要。
- 「Ingress だけで完結」しない（AppGW リソースの管理が絡む）。
- 証明書 Issued 前に AppGW を apply すると失敗する順序依存。

**（実検証で追加）デメリット**
- AGIC に `Managed Identity Operator` の付与が必要（AppGW に UAI を紐付けるため）。
  無いと `LinkedAuthorizationFailed` で AGIC が AppGW を一切更新できない。

### 方式 B（spec.tls + CSI）
**メリット**
- Ingress の `spec.tls` で完結でき、k8s ネイティブで一般的な書き味。
- AppGW 側 Terraform の証明書実装が不要（AGIC が面倒を見る）。
- 証明書を K8s Secret として他ワークロードからも参照しやすい。

**デメリット**
- **秘密鍵が K8s Secret に展開される**（etcd 保護・RBAC 設計が別途必要）。
- CSI Driver アドオン + SecretProviderClass + マウント Pod と可動部が多い。
- ローテーションが CSI→AGIC の 2 段で、経路が長く観測点が増える。
- `objectType` の指定ミス（certificate/secret）で無言で失敗しやすい。

**（実検証で追加）デメリット — こちらが本質的**
- **App Service Certificate ではそのままでは動かない。** KV へ証明書オブジェクトとして
  import する一段が必要（0 章 / findings.md 3-1）。
- その import が**スナップショットのコピー**になるため、**ASC の更新に自動追従しなくなる**。
  方式 B の売りだった「CSI(~2m) の自動ローテーション」が、ASC 相手では**成立しない**。
- 失敗が**無言**。Pod は Running、Ingress も正常に見えるのに Secret だけ生成されない。

---

## 5. 選定ガイド

### App Service Certificate（購入証明書）を使うなら → **方式 A**

理由は「秘密鍵をクラスタに出さない」だけではない。**構造上、方式 B では更新追従が壊れるため。**

```
方式A:  ASC 更新 → KV シークレット更新 → AppGW が versionless id で自動追従      ✅ 完結
方式B:  ASC 更新 → KV シークレット更新 → [import 済み証明書は更新されない] ✗
                                          → terraform apply し直しが必要
```

方式 B の CSI ローテーション（~2 分）は「KV の証明書オブジェクトが更新されること」が前提だが、
ASC が更新するのは**素のシークレットの方**であり、import したコピーは動かない。

### 方式 B が向くケース

- 証明書を **KV 証明書オブジェクトとして自前で管理**している（Let's Encrypt 自動更新、
  社内 CA からの import 運用など）。この場合 CSI は素直に動き、自動ローテーションも成立する。
- 証明書を K8s Secret として**他ワークロードからも参照したい**。
- Ingress の `spec.tls` に寄せて k8s ネイティブで統一したい。

### 迷ったら

**方式 A**。証明書の複製を増やさず、KeyVault を単一の真実の源にできる。

---

## 6. 参考

- AGIC TLS（K8s Secret と AppGW 証明書の両対応）:
  https://learn.microsoft.com/azure/application-gateway/ingress-controller-expose-service-over-http-https
- AppGW + KeyVault 証明書（keyVaultSecretId / MI / 自動ローテーション）:
  https://learn.microsoft.com/azure/application-gateway/key-vault-certs
- Secrets Store CSI Driver (Azure KeyVault provider) on AKS:
  https://learn.microsoft.com/azure/aks/csi-secrets-store-driver
- CSI で証明書を tls Secret に同期（objectType/secretObjects）:
  https://azure.github.io/secrets-store-csi-driver-provider-azure/docs/configurations/getting-certs-and-keys/
