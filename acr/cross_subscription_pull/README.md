# ACR クロスサブスクリプション Pull

サブスクリプション **A** の ACR にあるイメージを、サブスクリプション **B** の ACR へ移す構成を Terraform で管理する。
2 つの実装を併存させている。

| ディレクトリ | 方式 | 重さ | 使いどころ |
|---|---|---|---|
| [`image_import/`](image_import/README.md) | **`az acr import`**（trusted services） | 軽量・**推奨** | 同一 Entra テナントでイメージをコピーしたい（大半のケース） |
| [`image_pull_push/`](image_pull_push/README.md) | Runner VM で **docker pull/push**（VNet+PE+peering） | 重量・汎用 | クロステナント／実行時 private pull の検証／import に依存したくない |

どちらも前提は **両 ACR が Premium / `public_network_access_enabled = false`（完全プライベート）**、認証は **Managed Identity + RBAC**。
各ディレクトリは `from/`（A=ソース）と `to/`（B=取り込み先）に分かれる。

---

## 設計判断の経緯と訂正（重要・正直な記録）

この構成は、**アシスタントの誤った前提から出発し、後で訂正した**経緯がある。学習用に残しておく。

### 当初の（誤った）理解
「`az acr import` は、取り込み先(B)が private でも動くが、**ソース(A)が `public_network_access_enabled=false` だと
ソースを読めず import できない**（import は Private Endpoint を経由しないため）」と断定した。
この前提で、**VNet + Private Endpoint + VNet ピアリング + Runner VM による docker pull/push**（＝ `image_pull_push`）を実装した。

さらにユーザーから *「`network_rule_bypass_option = "AzureServices"` で解消しないのか？」「ACR import を bypass できないのか？」*
と問われた際にも、**「bypass の対象は ACR Tasks 等に限られ、クロスレジストリ import は対象外」と誤って回答**した。

### 真相（公式ドキュメントで確認）
ユーザーの指摘を受けて Microsoft 公式ドキュメントを確認した結果、**上記はすべて誤りだった**：

1. **ACR import 自体が「信頼サービス（trusted services）」**である。
   「Allow trusted services」一覧の表に
   *Azure Container Registry / Import images **to or from** a network-restricted Azure container registry* と明記されている。
2. したがって `allow trusted services`（= Terraform の `network_rule_bypass_option = "AzureServices"`、**既定で ON**）が
   有効なら、**同一 Entra テナント内であれば、public 無効の private ソースからでも import できる**。
   - ソースは **resource ID** で指定（`--registry <A の resource ID>`、`--source` は `repo:tag` のみ）。
   - import は ACR が Azure バックボーン経由で行うため、**顧客の VNet / Private Endpoint / ピアリング / VM は不要**。
3. 唯一の非対応は **「クロステナント × public 無効」**（*"Cross-tenant import isn't supported over public access disabled registry."*）。
   このケースでは `image_pull_push`（Runner で pull/push）が必要。

→ つまり **ユーザーの直感（bypass すれば import できる）が正しかった**。当初構成（`image_pull_push`）は「コピー目的」には過剰だが、
クロステナント等の用途で価値があるため `image_pull_push` として残し、本来軽量な正攻法を `image_import` として追加した。

### 出典リンク
- [Allow trusted services to access a network-restricted container registry — Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-registry/allow-access-trusted-services)
  （trusted services 一覧に「Azure Container Registry / Import images to or from a network-restricted registry」が記載）
- [Import container images to a container registry — Microsoft Learn](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-import-images)
  （*"To import to or from a network-restricted registry, the restricted registry must allow access by trusted services… import works."* /
  同一テナントで *"Public access to the source registry is disabled… specify the source registry by resource ID."* /
  *"Cross-tenant import isn't supported over public access disabled registry."*）

---

## 修正済み Public / Private 比較表

代表 2 方式を、A・B の公開状態の組み合わせで比較（**同一 Entra テナント前提**。trusted services は既定 ON）。

| ソース A | 先 B | `az acr import`（image_import） | Runner pull/push（image_pull_push） |
|---|---|---|---|
| public | public | ◎ 最も簡単（1 コマンド） | ◯（Runner はどこでも） |
| public | **private** | ◎（trusted services で先 private も可） | ◯ |
| **private** | public | ◎（resource ID 指定 + trusted services） | ◯ |
| **private** | **private** | ◎（**本来これで十分**） | ◎（VNet+PE+VM、重いが可） |
| **別テナント** × public 無効 | — | ✕ **import 非対応** | ◯ Runner なら可 |

**要点**
- **同一テナントなら import は全ケース ◎**（trusted services 有効が条件、既定 ON）。
- import が使えないのは **クロステナント × public 無効** のときだけ → `image_pull_push` を使う。
- 公開状態は各 `*/from/acr.tf` ・ `*/to/acr.tf` の `public_network_access_enabled` と `sku` で変更
  （PE 利用や public 無効化は Premium 必須）。

---

## どちらを選ぶか

- **まずは [`image_import`](image_import/README.md)**：同一テナントでコピーしたいだけなら、これが正解。VNet/PE/VM 不要。
- **[`image_pull_push`](image_pull_push/README.md)**：クロステナント、実行時 private pull の検証、または import の信頼サービス機構に
  依存したくない場合。

各ディレクトリの README に、適用順・RBAC・実行コマンドの詳細を記載している。
