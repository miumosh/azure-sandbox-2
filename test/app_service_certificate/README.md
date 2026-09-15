# app_service_certificate — 証明書 × AppGW/AGIC 検証

App Service Certificate（または自己署名）を KeyVault に用意し、
Application Gateway + AGIC（Helm）で TLS 終端に使う検証一式。
**証明書の用意** と **割り当て方式** を別ディレクトリに分離し、割り当て側は `data` 参照で疎結合にしている。

## ドキュメントの読み方

| ファイル | 内容 |
|---|---|
| **本 README** | 全体像・検証ステータス・結論のサマリ |
| **[`findings.md`](findings.md)** | ★**実検証で踏んだ罠の全記録**（エラー全文・原因・対処・デバッグ手順・一次情報） |
| [`keyvault_cert_using_pattern.md`](keyvault_cert_using_pattern.md) | 方式A/B の**設計比較**と選定ガイド |
| [`cert/az_cli_pattern.md`](cert/az_cli_pattern.md) | 証明書を **az CLI で運用する**手順（Terraform を使わない選択肢） |
| 各ディレクトリの `README.md` | **手順**と、そのディレクトリ固有のハマりどころ |

まず本 README で結論を掴み、実際に構築するときは各ディレクトリの README、
詰まったら [`findings.md`](findings.md) の「デバッグの入口」を引く、という使い方を想定している。

## ★もう 1 つの結論: 証明書オーダーは Terraform 管理に向かない

削除が**不可逆（＝証明書の失効）**、有料の一点物、KeyVault 紐付けが azurerm 未対応で
ARM テンプレート直書きが必要、恒久 diff、状態が Azure 側で勝手に遷移する — と、
Terraform と噛み合わない条件が揃っている。しかも**削除ロックは `terraform destroy` を止められない**。

> **推奨: 「証明書オーダーだけ az CLI、周辺（KV/DNS/assign-\*）は Terraform」のハイブリッド。**
> `assign-*` は KV を `data` 参照するだけなので、**cert/ を CLI 運用に替えても assign-\* は無改変**。
> → [`cert/az_cli_pattern.md`](cert/az_cli_pattern.md) / [`findings.md` 1-13](findings.md)

## 検証ステータス（2026-07-12 実施・すべて成功）

| 対象 | 状態 | 検証 URL |
|---|---|---|
| [`cert/`](cert/) `cert_source = app_service_order` | ✅ GoDaddy の本物の DV 証明書が Issued、KeyVault に格納 | — |
| [`assign-appgw-direct/`](assign-appgw-direct/) 方式A | ✅ 公開 HTTPS でチェーン検証込みに疎通 | `https://azure-app-service-cert-check.example.com` |
| [`assign-agic-csi/`](assign-agic-csi/) 方式B | ✅ 疎通したが **import 一段が必要**（後述） | `https://www.azure-app-service-cert-check.example.com` |

両方式とも **ローカル PC から `-k` なし・`--resolve` なしの素の `curl` で `HTTP 200` /
`ssl_verify_result: 0`**、チェーンは Go Daddy Root CA - G2 まで到達して `Verification: OK`。
提示証明書の拇印は両方式・KV シークレットのタグで一致（= **同じ 1 枚**）。

> 発行された証明書の SAN が 2 件（素のホスト名と `www.` 付き）あることを利用し、
> 方式A は素のホスト名、方式B は `www.` 付きを使って**同時に公開検証**している
> （A レコードの衝突を避けるため）。

`-k` なしで verify が通ることを合格条件にしたので、「証明書が載っている」だけでなく
**中間証明書まで含めて正しく提示されている**ことも同時に実証できている。

## ★結論: App Service Certificate を使うなら方式A

| | 方式A: AppGW が KV を直接参照 | 方式B: CSI → K8s Secret |
|---|---|---|
| KV の読み方 | AppGW が **versionless secret id** で直接読む | CSI がマウント → K8s Secret → AGIC がアップロード |
| **ASC 更新への追従** | ✅ **自動追従** | ❌ **追従しない**（import がスナップショットのため） |
| ASC を使う際の追加作業 | なし | **PFX を KV に「証明書オブジェクト」として import し直す必要** |
| 秘密鍵の所在 | KeyVault ⇄ AppGW のみ（クラスタに出ない） | K8s Secret (etcd) に materialize される |
| 必要な追加権限 | AGIC に `Managed Identity Operator`（UAI スコープ） | 不要 |

### なぜ方式B は素直に動かないのか

**すべての根源はこの 1 つの性質:**

> **App Service Certificate は KeyVault に「証明書オブジェクト」を作らない。
> 素のシークレットに、base64 エンコードされた PFX を入れるだけ。**

CSI の Azure プロバイダは「KV 証明書オブジェクトがある場合にだけ」PKCS12 → PEM 変換をする。
ASC のシークレットを直接指すと変換されず、代わりに CSI ドライバが変換する結果、
`tls.crt` に `localKeyId` ヘッダが混入しチェーンが逆順になり、AGIC の `openssl pkcs12 -export` が
`No cert in -in file matches private key` で失敗する。

回避策（KV へ証明書オブジェクトとして import）は成立するが、それは**スナップショットのコピー**なので、
**方式B の売りだった「CSI による自動ローテーション」が ASC 相手では成立しなくなる。**

→ 詳細・エラー全文・回避策の実装は [`findings.md` 3-1](findings.md) / [`assign-agic-csi/README.md`](assign-agic-csi/README.md)

## ディレクトリ構成

```
cert/                  ① 証明書を KeyVault に用意 (self_signed / app_service_order トグル)
                          → KV 名 / secret 名 / versionless id を output
   │  data 参照
   ├─▶ assign-appgw-direct/   ② 方式A: AppGW が KeyVault を直接参照 (annotation)
   └─▶ assign-agic-csi/       ③ 方式B: CSI で K8s TLS Secret に同期 (spec.tls)
```

| ディレクトリ | 役割 | 主なコスト |
|---|---|---|
| [`cert/`](cert/) | 証明書 → KeyVault。両モードで同名 secret を出力 | self_signed=無料 / order=有料(~$69/年) |
| [`assign-appgw-direct/`](assign-appgw-direct/) | 方式A（KeyVault リンク）。AKS+AppGW+AGIC | 大（AKS/AppGW） |
| [`assign-agic-csi/`](assign-agic-csi/) | 方式B（CSI+spec.tls）。AKS+AppGW+AGIC+CSI | 大（AKS/AppGW） |

どちらの assign-* も **公開 HTTPS 検証**（ローカル PC から素の curl）。テスト VM は使わない。

## 進め方（推奨）

1. **cert/ を `self_signed` で apply** → 無料で証明書を KeyVault に用意
2. assign-appgw-direct/ または assign-agic-csi/ を apply して**配管を検証**
3. 問題なければ cert/ を `app_service_order` に切替（有料・DNS 検証）

> ⚠️ **「割り当て側は無改変で切り替わる」は方式A だけ成立した。**
> 方式B は self_signed（KV 証明書オブジェクトができる）では動くが、
> app_service_order（シークレットのみ）に切り替えると壊れる。上記の結論を参照。

## 適用順序の制約

- **cert/ → assign-\*** の順。特に方式A は `data.azurerm_key_vault_secret` を plan 時に読むため、
  cert/ の証明書が KeyVault に存在（order は Issued）している必要がある。
- assign-* は基盤に AKS/AppGW を含む重い構成。同時に両方 apply できるよう名前は
  ディレクトリごとに分離済み（`certdirect-*` / `certcsi-*`）。

## 横断的なハマりどころ一覧

全 17 件を [`findings.md`](findings.md) に詳述。特に重要なものだけ:

| # | 内容 | 詳細 |
|---|---|---|
| 1 | 証明書の DNS 検証 TXT は **ルートドメイン `@`** に置く（CN がサブドメインでも） | [findings 1-2](findings.md) |
| 2 | KV に証明書を書き込むのは **`Microsoft.Azure.CertificateRegistration`** (`f3c21649-...`)。App Service RP と取り違えると Issued でも KV が空のまま | [findings 1-3](findings.md) |
| 3 | `Microsoft.CertificateRegistration` は **RP を登録しないと SP がテナントに生えない**。azurerm の自動登録セットにも含まれない | [findings 1-4](findings.md) |
| 4 | **ASC は KV に「シークレット」しか作らない**（証明書オブジェクトは無い）← 諸悪の根源 | [findings 1-1](findings.md) |
| 5 | **方式A: AGIC に `Managed Identity Operator` が必要**。無いと `LinkedAuthorizationFailed` で AGIC が AppGW を一切更新できない | [findings 2-1](findings.md) |
| 6 | **方式B: ASC のシークレットを CSI で直接読むと壊れる**。Pod は Running のまま Secret だけ黙って生成されない | [findings 3-1](findings.md) |
| 7 | **AGIC の Helm リポジトリ(Blob)は公開停止済み** → OCI (MCR) を使う | [findings 4-1](findings.md) |
| 8 | AppGW は作成時に KV を実際に読むため、**KV アクセスポリシーへの `depends_on` が必須** | [findings 2-3](findings.md) |
| 9 | `ignore_changes` の漏れ（`redirect_configuration`）→ 次の apply で AGIC の設定を Terraform が消しにいく | [findings 4-2](findings.md) |
| 10 | **KV への格納は自動ではない**。ポータルの「保存」は独立した ARM 子リソース。作らないと証明書が KV に入らない（azurerm 未対応） | [findings 1-8](findings.md) |
| 11 | **ARM/Terraform 経由では KV に削除ロックが付かない**（ポータル経由だと付く）。証明書の実体は KV にしか無いので誤削除が致命的 → `cert/locks.tf` で自前で付与 | [findings 1-9](findings.md) |
| 12 | **自動更新は 3 層の連鎖**（CA 再発行 / KV 新バージョン / AppGW が versionless id で追従）。どこで切れているかで切り分ける | [findings 1-10](findings.md) |

## 各ディレクトリの詳細

- 手順・そのディレクトリ固有の詰まりどころは各 `README.md` を参照。
- AGIC 本体は既存例 `aks/agic/helm/single_access_single_appgw` と同じく **Helm で手動導入**
  （Terraform は Azure リソースのみを管理）。

## 後始末の注意

**App Service Certificate の削除は取り消し不可（証明書が失効する）。** 有料リソースなので
`cert/` の `terraform destroy` は意図を確認してから。KV は soft-delete 有効（7日）のため、
同名 KV を作り直す場合は purge が必要。

`assign-*` は AKS/AppGW が課金対象なので、検証が済んだら destroy してよい
（証明書は cert/ 側に残るので再構築できる）。
