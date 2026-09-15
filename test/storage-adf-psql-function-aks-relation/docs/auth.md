# 認証・権限（Auth / IAM）整理

本プロジェクトで使用している ID・認証方式・権限付与を一覧で整理する。
「誰が（プリンシパル）」「何に対して（スコープ）」「どの権限を」「どの方式で」を明確化する。

---

## 1. マネージドID 一覧

| プリンシパル | 種別 | 定義場所 | 用途 |
| --- | --- | --- | --- |
| ADF | System-assigned MI | `modules/data_factory` | Storage への Blob アクセス。PostgreSQL へは **AAD/MSI 認証** |
| Function App | System-assigned MI | `modules/function_app` | PostgreSQL へ **AAD/MSI 認証**（トークンを password に） |
| AKS クラスター | System-assigned MI | `modules/aks` | VNet/サブネット参加など基盤操作（control plane） |
| AKS kubelet | MI（`kubelet_identity`） | AKS が自動作成 | ノードがイメージを pull する主体。Hub ACR への **AcrPull** 付与先 |
| 踏み台 VM | System-assigned MI | `modules/bastion` | psql への **AAD/MSI 接続**（参照のみの通常ロール。Entra 管理者にはしない） |

> 旧構成にあった「AKS ワークロード UAMI（Workload Identity で Functions を呼ぶ）」は、
> AKS → Function を **Function キー方式** に変更したため廃止した（UAMI / Federated Credential を撤去）。

### System-assigned と User-assigned の使い分け

どちらも「Azure AD 上の身元（プリンシパル）」を持つマネージドID で、**できること（トークン取得・RBAC/権限の付与先になる）は同じ**。違いは **ライフサイクルと参照のしかた**だけ。

| 観点 | System-assigned (SAMI) | User-assigned (UAMI) |
| --- | --- | --- |
| 実体 | 親リソースに**内蔵**（1 リソース = 1 ID） | **独立した Azure リソース**として単体で存在 |
| ライフサイクル | 親と同時に作成／削除（自動・管理不要） | 親とは独立。先に作れる・後まで残せる |
| 共有 | 不可（その親専用） | **複数リソースに付与・使い回し可** |
| 参照 | 親リソース経由で principal_id を取得 | **client_id / object_id で名指し**できる |
| 向く用途 | 「そのリソース自身として認証」 | 事前付与・共有・**外部からの名指し参照**が要る場合 |

**選び方（原則）**: 迷ったら **System-assigned**（1 リソース 1 ID で管理が最小、寿命も一致）。
次の事情があるときだけ **User-assigned** を選ぶ:

1. **リソースより先に ID を用意して権限を付けておきたい**（循環依存の回避・事前付与）。
2. **同じ ID を複数リソースで共有したい**。
3. **ID を「名指し」で参照する仕組みが要る** — 代表が **AKS Workload Identity**。
   フェデレーション資格情報（`federated_identity_credential`）は **UAMI にしか付けられず**、
   Pod の ServiceAccount が **client_id で ID を指名**するため、安定して参照できる ID が必須。

**本プロジェクトの使い分け**:

- **System-assigned のみ**: ADF / Function / 踏み台 VM / AKS クラスター。いずれも「そのリソース自身」として
  認証するだけで、共有も事前作成も不要 → SAMI が最小コスト。
- **User-assigned は不使用**: 以前は AKS ワークロード（Pod）が Functions を呼ぶために UAMI +
  Workload Identity を使っていたが、AKS → Function を **Function キー方式** に変更したため撤去した。
- ⚠️ AKS には**役割の違う MI が 2 つ**出てくるので混同しない:
  ①クラスター MI（System / control plane が VNet 等を操作）②kubelet MI（AKS が自動作成 / ノードの ACR pull）。
  いずれも AKS 基盤用で、Pod アプリの Function 呼び出し認証は MI ではなく **Function キー**で行う。

---

## 2. ロール割り当て（RBAC）

| 割り当て先 | ロール / App Role | スコープ | 定義場所 |
| --- | --- | --- | --- |
| ADF MI | `Storage Blob Data Contributor` | アップロード/アーカイブ用 Storage Account | `modules/storage` (`adf_storage_contrib`) |
| AKS kubelet MI | `AcrPull` | Hub の ACR（`ci00acr`） | `modules/container_registry` (`aks_acrpull`)（cross-sub） |

> AKS → Function の認証は **Function キー方式**に変更したため、旧構成の App Role `Persons.Read`
> 割当（`aad.tf`）は撤去済み。Function App への AAD ロール割当も無い。

### ⚠️ AcrPull 未付与で ImagePullBackOff（ハマりどころ）

Private ACR からの pull は **kubelet MI への AcrPull が必須**。実機で詰まった点:

- AcrPull ロール割当（`modules/container_registry` の `aks_acrpull`）は **`count` ガード**で、
  Hub の **`aks_kubelet_object_id`（spoke output）を設定して hub apply** しないと作られない。
  ACR 作成時にこれを空のまま apply すると AcrPull が無く、kubelet が**匿名**で pull → `401 Unauthorized`
  → Pod が **ImagePullBackOff**。
- apply 順序: Spoke apply で AKS 作成 → `aks_kubelet_object_id` を取得 →
  **Hub tfvars に設定して hub apply**（cross-sub のロール割当は ACR(scope) 側＝Hub provider で作る）。
- 切り分け: `kubectl describe pod` の Events に `401`/`anonymous token`、
  `az role assignment list --assignee <kubelet-oid> --scope <acr-id>` が空なら AcrPull 未付与。
- なお ACR の FQDN がエラーに出て **401（タイムアウトではない）** なら、PE/DNS は到達できていて
  **認可だけの問題**（DNS/PE は正常）。

---

## 3. AKS → Functions の認証（Function キー方式）

シンプルさと手動検証のしやすさを優先し、**Function キー方式**を採用する
（Easy Auth / AAD アプリ / Workload Identity は不使用）。

- **Function 側（受け）**: `modules/function_app`
  - Python v2 モデルの route が **`auth_level=FUNCTION`**（`FunctionApp(http_auth_level=FUNCTION)`）。
    Functions ホストが `x-functions-key`（または `?code=`）の関数キーを検証し、無効なら **401**。
  - Terraform は `azurerm_function_app_host_keys` で **default host key** を取得し、
    output `function_default_key`（`sensitive`）で公開する。
  - 受信は引き続き **Private Endpoint 経由のみ**（閉域）に限定。
- **AKS 側（呼び）**: `apps/aks/*/k8s/deployment.yaml`
  - Function キーを **Secret** に格納し、Pod へ環境変数 `FUNCTIONS_KEY` として渡す。
  - アプリ（`main.py`）は `x-functions-key: <FUNCTIONS_KEY>` ヘッダを付与して Function を呼ぶ。
  - Workload Identity の ServiceAccount 注釈 / Pod ラベル / UAMI / Federated Credential は不要。

**キーの流れ**: Terraform output `function_default_key` → k8s Secret → Pod の `FUNCTIONS_KEY` →
`x-functions-key` ヘッダ → Functions ホストが検証。

> Function キーは**共有シークレット**のため、Secret 管理（ローテーション含む）が前提。
> なお **Function → PostgreSQL** の接続は引き続き Function の System-assigned MI + AAD 認証
> （こちらは変更なし。マネージドID に PostgreSQL アクセス権限を付与）。

---

## 4. PostgreSQL の認証（Entra ID / マネージドID）

PostgreSQL は **Flexible Server**。Entra ID 認証を有効化し、ADF / Function は
マネージドID で接続する（パスワードレス）。

### 簡略化した捉え方（メンタルモデル）

「MI に DB の権限を登録する」を **社員証と建物の入館管理**にたとえると分かりやすい:

- **マネージドID = Azure AD が発行する社員証（ID バッジ）**。アプリは社員証をかざして
  「入館用トークン」を受け取る。
- **PostgreSQL は独立した建物**で、Azure とは別に**独自の入館名簿（ロール）と部屋の鍵（GRANT）**を持つ。
- ここがポイント: **社員証（トークン）が有効でも、PostgreSQL の名簿に名前が無ければ入れない。**
  Azure 側で MI を作っただけ・RBAC を付けただけでは DB には入れない。

やることは **3 ステップ**だけ:

1. **ID を発行**: マネージドID を作る（Terraform。①の社員証の発行）。
2. **名簿に登録**: 「この社員証（= object_id）の持ち主を、この DB ユーザーとして受け入れる」と
   PostgreSQL に登録する。これが `pgaadauth_create_principal_with_oid(<名前>, <object_id>, 'service', …)`。
   ＝ 社員証番号と DB ユーザー名を**ひも付け**する作業。
3. **鍵を渡す**: そのユーザーが触れるテーブル/操作を `GRANT`（と所有権）で決める。＝ どの部屋に入れるか。

> ① は Azure（Terraform）、②③ は SQL（**Entra 管理者で最初に一度だけ**）。
> 名前ではなく **object_id** で登録するのは、社員番号で照合する方が確実（名前照合は Microsoft Graph
> への問い合わせが必要で、サーバ権限が無いと失敗しやすい）だから。

**接続時に起きること（パスワードレス）**: アプリは社員証でトークンを取得し、psql 接続の
**password 欄にそのトークンを入れる** → サーバが「このトークンの object_id は名簿の誰か？」を照合 →
一致したロールの権限（GRANT 済みの範囲）で動作する。だから DB 内の権限は **GRANT で付けた分だけ**。

以下はこのモデルを正確に言い直したもの（2 層・グローバル/ローカルの整理）。

### 前提: アクセス制御は2層（Azure RBAC + PostgreSQL ロール）

MI がテーブルを操作するには **2つの層**で権限が要る。Azure 側の権限だけでは DB 内は触れない:

- **コントロールプレーン（Azure RBAC / Portal の IAM）**: Azure リソースの管理操作を制御する層。
  これだけでは DB 内のテーブルにアクセスできない。
- **データプレーン（PostgreSQL のロール / GRANT）**: DB ログインやテーブルの SELECT/INSERT は
  PostgreSQL 自身のロールと権限で制御する層。**MI に対応する PostgreSQL ロールを作成し、GRANT する**
  必要がある（＝ミドルレベルでの権限付与）。

ロールまわりは「**2つの単位**」を分けて捉えると分かりやすい:

- **MI を PG ロールとして登録**するのが `pgaadauth_create_principal*`。
  - **Entra 管理者**セッションでのみ実行可能（初回の登録時）。
  - 関数の都合で **`postgres` DB で実行**する。
  - ただし**作成されるロールはクラスタ全体で共有**（PostgreSQL のロールは DB 単位ではなく
    **クラスタ単位**のオブジェクト）。→ これが「グローバル」の正体。postgres で 1 回作れば全 DB から参照できる。
- **実際のテーブル権限（`GRANT SELECT` / 所有権）は DB・オブジェクト単位**で、対象テーブルのある
  **`appdb` に設定**する（グローバルではない）。

まとめると「**ロール = グローバル（クラスタ共有）／テーブル権限 = その DB 内ローカル**」。
`pgaadauth` を postgres で実行するのは関数がそこにしか無いためで、結果として作られるロールは全 DB 共有になる。

- **サーバ設定**（`modules/postgresql`）
  - `authentication { active_directory_auth_enabled = true, password_auth_enabled = true }`
  - `azurerm_postgresql_flexible_server_active_directory_administrator`：Entra 管理者。
    この管理者で psql に AAD 接続し、各 MI のロールを作成する。
- **MI ロールの作成と最小権限**（Entra 管理者で実行、2 ファイルに分割）
  - `apps/psql/.../create-aad-roles.sql`（**postgres DB**）で
    `pgaadauth_create_principal_with_oid('<名前>', '<object_id>', 'service', false, false)` により
    `ci00-adf` / `ci00-func` / `ci00-jumpbox` を作成（詳細は下の「pgaadauth の注意点」）。
  - `apps/psql/.../create-tables.sql`（**appdb**）で権限付与:
    ADF はテーブルの**所有権**（DROP/RENAME のため）、Function / 踏み台は **SELECT のみ**。
  - ロール名は各 MI 表示名（= リソース名 `ci00-adf` / `ci00-func` / `ci00-jumpbox`）に一致させる。
- **ADF（呼び出し側）**：`modules/data_factory` の `azapi_resource.ls_psql`
  （V2 リンクサービス、`authenticationType = SystemAssignedManagedIdentity`）。
  azurerm の `linked_custom_service` バグ回避のため azapi で MS 公式 JSON を直接投入
- **Function（呼び出し側）**：`files/function_app/customer_search/src/database.py` が
  `DefaultAzureCredential` で `https://ossrdbms-aad.database.windows.net/.default` のトークンを取得し
  psycopg の password に渡す。`PSQL_USER` = Function App 名（= MI 表示名）、`PSQL_PASSWORD` は不要
- **踏み台 VM（呼び出し側）**：`ci00-jumpbox`（VM の MI）を**参照のみの通常ロール**として登録。
  日常の psql 接続は `az login --identity` → `az account get-access-token`（`ossrdbms-aad`）で
  パスワードレス。`pgaadauth_create_principal_with_oid('ci00-jumpbox', '<object_id>', 'service', ...)`
  で作成（MI は名前解決に Graph 権限が要るため object_id 明示が堅い）

### 設計原則：Entra 管理者と MI ロールの分離

- **Entra 管理者は人間ユーザー/グループに限定**し、用途は「一度きりのブートストラップ
  （`pgaadauth_create_principal` による各 MI ロール作成）」のみ。
- **各 MI（ADF / Function / 踏み台）は最小権限の通常ロール**。MI を Entra 管理者にはしない
  （DB 全体への管理権限は過大なため）。
- `pgaadauth_create_principal` は Entra 管理者セッションでのみ実行可能。接続・クエリ自体は
  通常ロールで足りる（＝MI に管理者権限は不要）。

### pgaadauth の注意点（重要 / ハマりどころ）

AAD ロール作成で実際に詰まった点。参考: Microsoft Q&A
[pgaadauth_create_principal does not exist](https://learn.microsoft.com/en-us/answers/questions/1655608/pgaadauth-create-principal-does-not-exist-in-my-fl)。

1. **`pgaadauth_*` 関数は `postgres` データベースにしか存在しない。**
   `appdb` 等のユーザー DB で実行すると `ERROR: function pgaadauth_create_principal(...) does not exist`。
   → ロール作成は **postgres DB** で行う（`create-aad-roles.sql`）。PostgreSQL のロールは
   クラスタ全体で共有されるため、作成後は `appdb` の GRANT/所有権付与から参照できる。

2. **MI（サービスプリンシパル）は `_with_oid`（object_id 明示）で作成する。**
   名前ベースの `pgaadauth_create_principal('name', ...)` は表示名を Microsoft Graph で解決するため、
   サーバ側に Graph 権限が無いと失敗しやすい。`pgaadauth_create_principal_with_oid('name', '<oid>', 'service', ...)`
   なら Graph 解決不要で確実。第3引数はマネージドID/SP なら `'service'`、ユーザーなら `'user'`。
   object_id は terraform output（`data_factory_principal_id` / `function_principal_id` /
   `jumpbox_principal_id`）から取得する。

3. **Entra 管理者セッションでのみ実行可能**（前述）。bootstrap は人間の Entra 管理者で一度だけ。

4. **作成・GRANT の順序**: `postgres` でロール作成 → `appdb` で GRANT/所有権付与。
   Function/踏み台への SELECT 付与を先に行い、最後に ADF へ所有権移譲する
   （明示 GRANT は OWNER 変更後も保持される）。

→ 症状ベースの記録は [troubleshooting.md #11](./troubleshooting.md) も参照。

## 5. その他のデータプレーン認証（キー / パスワード）

| 対象 | 方式 | 場所 | 備考 |
| --- | --- | --- | --- |
| Storage（Storage Explorer アップロード） | サービス SAS（IP 制限・30 日・最小権限） | `modules/storage` (`data...blob_container_sas.upload`) | read/add/create/write/list。delete 不可 |
| Storage（共有キー） | `shared_access_key_enabled = true` | `modules/storage` | SAS 発行のため有効化 |
| PostgreSQL（SQL 管理者） | SQL 認証（admin login/password） | `modules/postgresql` | bootstrap / break-glass 用に併存 |
| 踏み台 VM | パスワード認証 | `modules/bastion` | 検証用。本番は SSH 鍵 + AAD ログイン推奨 |

---

## 6. トークンスコープ早見表

各呼び出し側が「何の audience/scope に対して」トークンを取得するか。

| 呼び出し側 | 取得スコープ / audience | 認証方式 | 用途 |
| --- | --- | --- | --- |
| Function → PostgreSQL | `https://ossrdbms-aad.database.windows.net/.default` | System MI | DB 接続（password にトークン） |
| 踏み台 VM → PostgreSQL | `https://ossrdbms-aad.database.windows.net`（`az account get-access-token`） | VM の System MI | psql 接続 |
| AKS Pod → Functions | （AAD トークン不使用） | Function キー | `x-functions-key` ヘッダで Functions ホストが検証 |
| ADF → PostgreSQL | （ADF コネクタが内部取得） | ADF System MI | Managed PE 経由の DB 接続 |
| ADF → Storage | （ADF コネクタが内部取得） | ADF System MI | Managed PE 経由の Blob アクセス |

---

## 7. 資格情報（シークレット）の所在

AAD/MI 化により、state や設定に残るパスワード系シークレットは最小化されている。

| シークレット | 残存箇所 | 備考 |
| --- | --- | --- |
| `psql_admin_password` | Spoke の tfvars / state（sensitive） | bootstrap / break-glass 用。AAD 専用化で除去可能 |
| `jumpbox_admin_password` | Hub の tfvars / state（sensitive） | 本番は SSH 鍵 + AAD ログインで除去可能 |
| Storage SAS / 共有キー | Hub の state（output は sensitive） | Storage Explorer アップロード用 |
| 関数キー（`function_default_key`） | Spoke の state（output は sensitive）/ k8s Secret | **AKS→Functions の認証に使用**（共有シークレット。ローテーション運用が前提） |
| PG パスワード（ADF/Function） | **廃止済み** | いずれも AAD/MI トークン |

> tfvars は `.gitignore` 済み。state にも sensitive 値が入るため、本番ではリモート
> state（暗号化 + アクセス制御）と Key Vault 参照の併用を推奨。

---

## 8. デプロイ実行者に必要な権限

| 操作 | 必要権限 |
| --- | --- |
| Hub / Spoke の各リソース作成 | 各サブスクリプションの Owner または Contributor |
| Managed PE（ADF）の承認 | 対象（Storage/PSQL）の `Microsoft.Network/privateEndpointConnections` 承認アクション（Owner/Contributor 相当） |
| ロール割り当て（RBAC） | 対象スコープの `Microsoft.Authorization/roleAssignments/write`（User Access Administrator/Owner） |

---

## 9. 本番強化の指針

- PostgreSQL の SQL 管理者 → 可能なら `password_auth_enabled = false` で **AAD 専用**に
- ADF→PG は azapi で V2 リンクサービスを作成。動作確認は ADF Studio の Test connection で行う
- 踏み台 VM → **SSH 鍵 + AAD ログイン**（パスワード認証を無効化）
- Storage の共有キー → 可能なら無効化し、SAS も用途を絞る／短期化

## 関連

- ネットワーク側の制御は [network.md](./network.md) を参照。
- ADF 取り込みパイプラインの構成・落とし穴は [pipeline.md](./pipeline.md) を参照。
