# 検証結果 — ACR クロスサブスクリプション import の RBAC 制御

実施日: 2026-10-19
関連: [research.md](research.md)（机上調査） / [verify_simple.md](verify_simple.md)（実施した手順） / [VERIFY.md](VERIFY.md)（詳細な検証項目）

## 1. 結論

**サブスク A のソース ACR に `Container Registry Data Importer and Data Reader` だけを付与した Entra ユーザで、A → B へのクロスサブスクリプション import が成功した。**

- トークン / admin user / SP シークレットは使わず、ユーザ自身の Entra 権限＋ RBAC だけで import できた。
- A 側の権限はサブスクリプションや RG ではなく、**ソース ACR リソース単位**の割り当てで足りた。
- 両 ACR とも **public 無効**（trusted services ON）だったが、VNet / Private Endpoint なしで import できた。

---

## 2. 検証環境

| 項目 | 値 |
| --- | --- |
| テナント | `<TENANT_ID>`（同一テナント） |
| サブスク A（ソース） | `<SUB_A_ID>` |
| サブスク B（取り込み先） | `<SUB_B_ID>` |
| ソース ACR | `acrimprbacsrc1ext0m`（RG: `acr-import-rbac-a-rg`、japaneast） |
| 取り込み先 ACR | `acrimprbacdst1ext0m`（RG: `acr-import-rbac-b-rg`、japaneast） |
| ACR 構成（両方） | Premium / `publicNetworkAccess: Disabled` / `networkRuleBypassOptions: AzureServices` / export policy enabled / ロール割り当てモード `LegacyRegistryPermissions`（RBAC-only） |
| ソースのイメージ | `hello-world:latest`（`mcr.microsoft.com/hello-world:latest` を管理者が import して投入） |
| 構築方法 | [`terraform/`](terraform/)（1 つの構成で A / B 両方を管理） |
| Azure CLI | 2.84.0 |

### オペレータ（test-user-01）の権限

| スコープ | ロール | 備考 |
| --- | --- | --- |
| サブスク B 全体 | Owner | 前提条件（事前付与） |
| ソース ACR（A） | Container Registry Data Importer and Data Reader | Terraform で付与 |
| 取り込み先 ACR（B） | Container Registry Data Importer and Data Reader | Terraform で付与（Owner と重複するため実質影響なし） |

サブスク A には、ソース ACR へのロール以外に何も付与していない。

---

## 3. 実施内容と結果

### 3.1 import（test-user-01 で実行）

```bash
az acr import \
  --name acrimprbacdst1ext0m \
  --subscription <SUB_B_ID> \
  --registry /subscriptions/<SUB_A_ID>/resourceGroups/acr-import-rbac-a-rg/providers/Microsoft.ContainerRegistry/registries/acrimprbacsrc1ext0m \
  --source hello-world:latest \
  --image step1/hello-world:latest
```

**結果: 成功**（出力なし・エラーなしで終了）

### 3.2 取り込み先のアクティビティログ

```
Who                                        Status    Sub       Time
-----------------------------------------  --------  --------  ----------------------------
test-user-01@<tenant>.onmicrosoft.com  Accepted  Accepted  2026-10-19T12:08:45.0271788Z
test-user-01@<tenant>.onmicrosoft.com  Started             2026-10-19T12:08:44.8084214Z
```

- 呼び出し元 UPN 付きで `importImage/action` が記録された。
- import は非同期処理（202 Accepted）のため、**`Succeeded` の行は記録されなかった**。完了したかどうかはアクティビティログでは判断できない。

### 3.3 取り込み先にタグが存在することの確認（管理者で実行）

両 ACR とも public 無効のため、手元からの `az acr repository show-tags` は 403 になる。
代わりに、**取り込み先の中で ARM 経由の import をもう一度行い**、元のタグが存在するかを確かめた。

| ソース | 結果 |
| --- | --- |
| `step1/hello-world:latest`（3.1 で取り込んだタグ） | 成功 → タグが存在する |
| `nonexistent/repo:latest`（比較用） | 失敗: `InvalidParameters` / `Unable to find manifest digest  Repo: nonexistent/repo Tag: latest` |

---

## 4. research.md との照合

| research.md の記述 | 結果 |
| --- | --- |
| 同一テナントならトークンなしで `--registry <リソース ID>` 指定の import ができる | **確認できた** |
| ソース・取り込み先とも private でも、trusted services ON なら import 可能 | **確認できた**（VNet / PE なし） |
| A 側のロールは ACR リソース単位の割り当てで足りる | **確認できた** |
| import は ARM の制御プレーン操作で、オペレータ端末から `*.azurecr.io` への到達は不要 | **確認できた**（データプレーンは 403 だが import は成功） |
| 取り込み先のアクティビティログに呼び出し元 UPN 付きで記録される | **確認できた**（ただし `Started` / `Accepted` のみで `Succeeded` は出ない） |
| public 無効の ACR でも管理者が公開レジストリから import でイメージを投入できる | **確認できた**（Terraform の `terraform_data.seed_image`） |

---

## 5. 未実施の項目

今回は「現状で import できるか」の確認のみ。以下は未実施（手順は [VERIFY.md](VERIFY.md)）。

| # | 項目 | 状態 |
| --- | --- | --- |
| 2 | ソース側のロールを外すと失敗するか、エラーメッセージの内容 | 未実施 |
| 3 | ソース側の最小権限（カスタムロール: `registries/read` + `pull/read` など） | 未実施 |
| 4 | ソースを ABAC モードにして、リポジトリ条件付きの Repository Reader で制御できるか | 未実施 |
| 5 | ソースの export policy を無効にしたときのエラー | 未実施 |
| 6 | ソース A 側のログに何が残るか | 未実施 |
| 7 | 条件付きアクセスによる接続元 IP の制限 | 未実施 |

> 取り込み先側のロールを外すケース（research.md §6 の 3）は、オペレータが B の Owner を持つことが前提条件のため対象外とした。

---

## 6. 気づいた点・注意点

- **import の完了はアクティビティログでは追えない**: `Started` / `Accepted` までしか出ない。完了判定は `az acr import` の終了コード（CLI は完了までポーリングし、失敗時はエラーを出す）で行う。
- **public 無効の ACR の中身確認**: データプレーンが使えないため、「取り込み先の中で import し直す」方法がタグの存在確認に使える（ARM 経由のため）。
- **Azure CLI のログイン状態の取り違えに注意**: 管理者とオペレータの `az` 設定を `AZURE_CONFIG_DIR` で分けたが、`export` を設定した端末と設定していない端末を行き来するうちに、**既定の `~/.azure` がオペレータ、分けたディレクトリが管理者**と逆になった。このため最初の `terraform destroy` がオペレータの権限で実行され 403 で止まった（何も削除されていない）。作業前に `az account show --query user.name` で誰として動いているかを確認すること。

---

## 7. 後片付け

2026-10-19 に `terraform destroy` で全リソースを削除した（8 リソース）。

- 両サブスクの RG（`acr-import-rbac-a-rg` / `acr-import-rbac-b-rg`）が存在しないことを確認。
- サブスク A に test-user-01 へのロール割り当てが残っていないことを確認。
- サブスク B の Owner（前提条件）は残している。
