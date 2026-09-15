# Function デプロイパッケージ (run-from-package)

ローカルでビルドした zip を、**Hub の踏み台 VM 上から Storage の `deployments` コンテナへアップロード**し、
`WEBSITE_RUN_FROM_PACKAGE` で Function に読み込ませる（SCM 不使用＝閉域のままデプロイ）。
**Terraform は zip を upload しない**（blob 名を変数で参照するだけ）。
成果物 Storage は **完全閉域（`public_network_access=false` + blob/queue/table の Private Endpoint）**、
**共有キー無効 + Entra RBAC**。踏み台 VM のサブネット（`snet-jumpbox`）だけ PE サブネットの NSG で許可。

**デプロイ手順（恒久・手動。CI/CD は採用しない）**:

1. **ビルド**（下記「zip のビルド手順」）して `api-YYYYMMDD.zip`（日付サフィックス）を作る。
2. **踏み台 VM 上で**ユーザーの Entra アカウントで `az login` → `deployments` コンテナへアップロード:
   ```bash
   az storage blob upload --auth-mode login \
     --account-name <funcst名> --container-name deployments \
     --name api-YYYYMMDD.zip --file ./api-YYYYMMDD.zip
   ```
   - 共有キー無効のため **Entra RBAC のみ**。アップロードするユーザー/グループに `Storage Blob Data Contributor`
     （`deployments` コンテナ）が必要（`uploader_principal_ids` で付与）。VM の MI は使わない。
   - blob アップロードは**データ面**なので、PE に到達できる**踏み台 VM から**実行する（ローカル不可）。
3. **`func_package_name` を当該 blob 名に更新して `terraform apply`**。
   `WEBSITE_RUN_FROM_PACKAGE` が更新され、**アプリ設定変更で Function が自動再起動**して反映される（手動再起動不要）。
   - コンテナは azapi（ARM コントロールプレーン）で作るため、**`terraform apply` 自体はローカルからでも実行可能**
     （データ面に触れるリソースが無い）。
4. **疎通確認**: AKS から Function キー経由で `POST /api/customers/search` → 200。

> ⚠️ **順序厳守**: 先に zip をアップロードしてから apply（apply で即再起動するため、未アップロードだと起動失敗）。
> **Blob アップロードだけでは反映されない**（`func_package_name` 更新 + apply が必須）。
> 役割分担: **zip アップロード = 踏み台 VM（データ面）/ `terraform apply` = ローカル可（コントロールプレーン）**。
> Function は Storage を **MI（共有キー無効）** で読む。Function キーは `azure-webjobs-secrets` blob 格納のため、
> MI の Storage Blob ロールがキー認証維持の根拠。

- ソースコードは同ディレクトリの **`src/`** 配下（ビルド済み zip は **`build/`**）。
  **Python v2 モデル（デコレーター方式）**で、`function_app.py` をエントリに **3 ファイル構成**:
  - `function_app.py` … FunctionApp を作り Blueprint を登録するだけ
  - `api.py` … 本人特定 API を 1 ファイルに集約（Blueprint + ハンドラ `search_customers` + 正規化 `normalize_*` + 検証 `validate_*` + 入力境界 `parse_request` + DB照合 `search` + HTTP応答 `ok`/`bad_request`/`error`）。セクションコメントで区切る
  - `database.py` … PostgreSQL 接続（MSI/AAD トークンで DSN を組み立て）。`connection_string()`
  - `host.json` / `requirements.txt` … アプリ単位（v2 は function.json 不要）
- AKS -> Function の認証は **Function キー方式**（route の `auth_level=FUNCTION`）。
- v2 モデルのため Function App 側に `AzureWebJobsFeatureFlags=EnableWorkerIndexing` を設定（`function.tf`）。
- zip はビルド成果物のため git 管理外（`.gitignore` 済み）。apply 前に手元でビルドして配置する。

## 命名規則（モジュール / 関数 / 識別子）

本人特定 API の Blueprint は、実態（顧客検索して `policy_no` を返す）に合わせて以下の名前を採用する。

| 対象 | 名前 | 規則 |
|---|---|---|
| 機能ディレクトリ | `customer_search/` | 名詞句・**単数修飾**（`customers_search` ではなく `customer_search`） |
| 本体モジュール | `api.py`（`src/api.py`） | 内側は汎用名（外側が `customer_search/` のため重複回避） |
| ハンドラ関数 | `search_customers`（`api.py`） | **動詞始まり**（関数＝動作）。複数件マッチし得るので目的語は複数形 |
| Blueprint 変数 | `customer_search_bp`（登録時の別名） | snake_case |
| ルート | `customers/search` | パスは **REST 複数形**のまま（コード識別子とは別物） |

規則の指針:

- **モジュール/ファイル = 名詞句（単数修飾）**、**関数 = 動詞始まり**、で名詞/動詞を使い分ける。
- **アンダーバー vs ハイフン**:
  - **snake_case（アンダーバー）** … import される Python 識別子（`.py` モジュール名・関数名・変数名）。
    ハイフンは Python 識別子として文法的に不正（`import customer-search` はエラー）。
  - **kebab-case（ハイフン）** … import しないもの（ディレクトリ名・URL/ルート・コンテナイメージ・k8s リソース・PyPI 配布名）。
  - 例: `function_app.py`/`database.py`/`api.py`（アンダーバー）、AKS アプリの**ディレクトリ** `app-for-getting-person-id`（ハイフン）。

## 依存ビルド方式（なぜ run-from-package か）

Azure Functions（Python / Linux）は「**依存パッケージをどこで復元/ビルドするか**」を選べる。
本リポジトリは閉域制約から **run-from-package（サーバ側ビルドなし）** を採用している。

| 方式 | ビルドのタイミング / 場所 | 必要なもの | 閉域適合 |
|---|---|---|---|
| リモートビルド（Oryx/Kudu） | **デプロイ時にサーバ側**で `requirements.txt` を復元 | SCM/Kudu ＋ PyPI への外向き通信 | ✗ |
| ローカルビルド | **手元**で依存を取得して同梱 | ローカルで wheel 取得 | △〜○ |
| **run-from-package（本リポジトリ）** | **ビルドなし**。依存込み zip を読み取り専用マウント | 事前ビルド済み zip のみ | ○ |

- **用語の正確化**: ここでの「ビルド」は *デプロイ時のサーバ側ビルド* を指す（関数のリクエスト処理時に
  ビルドは走らない）。本 README で言う「実行時ビルドが無い」＝「**Oryx/Kudu によるデプロイ時ビルドが無い**」。
- **制御スイッチ**（どの方式になるかを決める設定）:
  - `SCM_DO_BUILD_DURING_DEPLOYMENT`（`true`/`false`）… Kudu/Oryx がデプロイ時にビルドするか
  - `ENABLE_ORYX_BUILD` … Oryx ビルドの有効/無効
  - `WEBSITE_RUN_FROM_PACKAGE` … パッケージを読み取り専用マウントで実行（**ビルドなし**）← 本リポジトリ採用
  - `func azure functionapp publish` の `--build remote|local` / `--no-build` / `--build-native-deps`
- **選定理由**: 本構成は閉域（`public_network_access=false`・SCM 不使用）のため、サーバ側ビルド
  （リモートビルド）は使えない。よって**手元で Linux/cp313 wheel を集めて zip 化**し、
  `WEBSITE_RUN_FROM_PACKAGE` で読み込ませる（＝下記「zip のビルド手順」）。

### SCM / Kudu とは

- **Kudu** = Azure App Service / Functions の「**デプロイと管理を担うエンジン**」。その実体が
  **SCM サイト**（Advanced Tools）。**SCM** = Source Control Management の略で、
  「Kudu サイト」「SCM サイト」「Advanced Tools (Kudu)」はほぼ同義。
- **URL の例**: アプリが `https://myfunc.azurewebsites.net` なら、SCM サイトは**別ホスト名**の
  `https://myfunc.scm.azurewebsites.net`。
- **役割**: zip deploy / git push の受け口、**Oryx によるリモートビルドの実行場所**、ファイル閲覧・
  コンソール・ログストリームなど。リモートビルド（`SCM_DO_BUILD_DURING_DEPLOYMENT=true`）はこの
  SCM サイト上で走る。
- 本 README の「**SCM 不使用**」= この SCM 経由のデプロイ/ビルドを使わず、run-from-package
  （blob からマウント）にする、という意味。

### 閉域化（VNet統合）すると zip 必須か？

**「VNet統合したから zip 必須」ではない。** 正しくは次の因果による:

1. 閉域化で起きること: **(a)** inbound を Private Endpoint のみにすると **SCM サイトもインターネットから
   到達不可**、**(b)** outbound を VNet 限定にして egress 無しだと **Oryx が PyPI に到達不可**。
2. → **リモートビルド（Oryx）が使えなくなる**。
3. → 依存は**事前同梱**するしかない。その標準が **run-from-package（依存込み zip を blob からマウント）**。

つまり「閉域化 → リモートビルド不可 → 依存を事前ビルドして同梱（＝run-from-package の zip）」となり、
**実質的にはほぼ zip 必須**。

| 状況 | リモートビルド(Oryx) | デプロイに必要なもの |
|---|---|---|
| 開放（SCM 公開 ＋ PyPI egress 有） | 使える | zip 不要。`requirements.txt` を置けばサーバ側が依存を解決 |
| **閉域（PE のみ ＋ egress 無）** | **使えない** | **事前ビルド済み zip**（run-from-package）← 本リポジトリ |

> 厳密な別解: VNet 内の自前エージェントや Bastion 経由で SCM に到達し、ローカルビルド成果物を zip deploy
> する方法もあるが手間。run-from-package は SCM を一切使わずに済むため最もシンプル。

## zip のビルド手順

run-from-package は実行時ビルドが無いため、**依存込み**でビルドする。
Linux/cp313 の wheel を明示取得するのでローカルの Python バージョンに依存しない
（`pip` と `zip` が必要）。リポジトリルートで実行:

```bash
APP="$(pwd)/terraform/envs/spoke-subscription/files/function_app/customer_search"
OUT="$APP/build/api-$(date +%Y%m%d).zip"   # 依存込み zip を build/ に日付名で出力
SRC="$APP/src"
BUILD="$(mktemp -d)"

cp -r "$SRC"/. "$BUILD"/
# v2 はアプリ単位の単一 requirements.txt
pip install --target "$BUILD/.python_packages/lib/site-packages" \
  --only-binary=:all: --platform manylinux2014_x86_64 \
  --python-version 3.13 --implementation cp \
  -r "$SRC/requirements.txt"

rm -f "$OUT"
( cd "$BUILD" && zip -qr "$OUT" . )
rm -rf "$BUILD"
echo "built: $OUT"
```

### コマンド各オプションの詳細

ねらいは「**ローカル環境に依存せず、Azure Functions Linux ランタイム（CPython 3.13 / glibc x86_64）で
そのまま動く wheel だけ**を集めて同梱する」こと。各オプションはそのための指定。

> **用語: wheel（ホイール）とは** — Python の**ビルド済み配布形式**（`.whl` / PEP 427）。pip は wheel を
> **展開するだけ**でインストールでき、ソースからのコンパイルが不要。対義は **sdist**（`.tar.gz` のソース配布で、
> インストール時にビルドが要る）。ファイル名にタグが埋め込まれ
> `{名前}-{版}-{python}-{abi}-{platform}.whl`（例: `psycopg_binary-3.3.4-cp313-cp313-manylinux2014_x86_64.whl`）。
> 純 Python パッケージは `…-py3-none-any.whl`（実装・ABI・OS 非依存）。C 拡張を持つ `psycopg-binary` も
> wheel があれば手元でコンパイル不要になる。

#### `--target .python_packages/lib/site-packages`（配置先）

- **Azure Functions Python の規約パス**。Functions の Python worker は、アプリルート直下の
  `.python_packages/lib/site-packages` を `sys.path` に追加して依存を読み込む。`func` CLI で
  `--no-build`（リモートビルドなし）/ run-from-package する場合に依存を置く標準レイアウトで、
  本リポジトリは run-from-package（実行時ビルドなし）なので**この配置が必須**。
- `pip install --target <dir>` は「そのディレクトリへ直接展開」する指定。仮想環境を作らず、zip に
  そのまま入れられる素のディレクトリツリーになる。
- ⚠️ 別名（`site-packages` 以外）に置くと worker が読み込まないので変更不可。

#### `--only-binary=:all:`（ソースビルド禁止 = wheel 限定）

- **すべてのパッケージをビルド済み wheel のみで取得**し、sdist（ソース配布）からのビルドを禁止する指定。
  `:all:` は「全パッケージ対象」の特別値。
- クロスターゲット（`--platform` / `--python-version` / `--implementation` で**手元と違う環境向け**に集める）
  ときは、pip はソースをビルドできないため **`--only-binary=:all:` が事実上必須**。これにより
  ローカルで C 拡張をコンパイルせず、Linux 向けの完成品 wheel をそのまま取得できる。
- 他の選択肢:
  - `--only-binary=psycopg,psycopg-binary` … 対象を**特定パッケージだけ**に限定。
  - `--prefer-binary` … wheel を優先しつつ無ければ sdist 許可（クロスターゲットでは不可）。
  - `--no-binary=:all:` / `--no-binary=PKG` … 逆に**ソースからビルド**を強制（手元 = 実行環境のとき用）。
  - `:none:` … 制限なし（既定動作）。

#### `--platform manylinux2014_x86_64`（対象 OS/CPU の wheel タグ）

- 取得する wheel の**プラットフォームタグ**を固定する。Azure Functions Linux は **glibc 系 Linux / x86_64**
  上で動くため、それに合う manylinux x86_64 wheel を取る。
- **唯一の選択肢ではない**。代表例:
  - `manylinux2014_x86_64`（= `manylinux_2_17_x86_64`, glibc 2.17 / PEP 599）… **対応範囲が広く安全な既定**。
  - `manylinux_2_28_x86_64`（glibc 2.28 / PEP 600）… 新しめ。**一部パッケージが manylinux_2_28 wheel しか
    配布しない**場合に使う。`--platform` は**複数回指定可**で、`--platform manylinux2014_x86_64
    --platform manylinux_2_28_x86_64` のように併記すると新旧どちらの wheel も許容できる。
  - `manylinux2010` / `manylinux1` … 旧世代（非推奨）。
  - ARM 系 SKU を使う場合は `*_aarch64`。本リポジトリの Function は x86_64 なので不要。
- 本リポジトリの依存では、C 拡張を持つ **`psycopg[binary]`（psycopg-binary）** が manylinux2014 wheel を配布
  しているため `manylinux2014_x86_64` で取得できる。`azure-functions` / `azure-identity` は
  純 Python（`py3-none-any`）なのでプラットフォームに依存しない。

##### `manylinux2014` のままで良いか / EOL について

- **結論: 当面そのままで良い**。`psycopg-binary` の現行版（例 3.3.4）は manylinux2014（=`manylinux_2_17`,
  glibc 2.17）wheel を**現に配布**しており、`manylinux2014_x86_64` でピタリ一致する。manylinux2014 wheel は
  glibc 2.17 以上で動く＝後方互換が広く、より新しい Azure Functions Linux ホストでも問題なく動作する。
- **EOL の考え方**: manylinux タグ自体に「EOL 日」は無いが、**ビルド基盤の OS の EOL に連動**する。
  manylinux2014 のビルドイメージは **CentOS 7 ベースで、CentOS 7 は 2024-06-30 に EOL**。これは
  「**配布側が今後 manylinux2014 wheel を作らなくなる**」方向の話で、既存 wheel が動かなくなるわけではない。
  新しめのパッケージは `manylinux_2_28`（glibc 2.28 / AlmaLinux 8）など新タグのみで配布する例が増えている。
- **将来対策（Tips）**: 依存が将来 manylinux2014 wheel をやめても壊れないよう、`--platform` を
  **新旧併記**しておくと堅牢（pip は新しいタグから試し、無ければ次へフォールバック。Azure Functions Linux は
  glibc 2.28+ を満たすため `manylinux_2_28` wheel も動作）。現状は 2014 がヒットするため必須ではない:

  ```bash
  pip install --target "$BUILD/.python_packages/lib/site-packages" \
    --only-binary=:all: \
    --platform manylinux_2_28_x86_64 \
    --platform manylinux2014_x86_64 \
    --python-version 3.13 --implementation cp \
    -r "$SRC/requirements.txt"
  ```

#### `--python-version 3.13` ＋ `--implementation cp`（対象 Python の wheel タグ）

- **`--implementation`** は wheel の Python 実装タグ。`cp` = **CPython**（Azure Functions の実行系）。
  `--python-version 3.13` と合わさって **`cp313`** タグの wheel を選ぶ。
- `--implementation` の他の選択肢: `pp`（PyPy）/ `ip`（IronPython）/ `jy`（Jython）/ `py`（実装非依存 =
  純 Python wheel `py3-none-any`）。**Azure Functions は CPython なので `cp` 固定**。なお純 Python wheel
  （`azure-functions` 等）は実装非依存タグのため `cp` 指定でも問題なくマッチする。
- ABI タグ（`--abi cp313`）は通常**省略で OK**（pip が implementation + version から推定）。明示したい場合のみ付ける。
- 3 箇所の Python 版（モジュールの `python_version` / 本ビルドの `--python-version` / wheel の `cp` タグ）は
  必ず一致させる（[バージョン管理方針](#バージョン管理方針ランタイム--依存パッケージ) 参照）。

> まとめると、`--only-binary=:all:` で「ソースを一切ビルドしない」、`--platform` / `--python-version` /
> `--implementation` で「Linux・CPython 3.13・x86_64 向けの完成 wheel だけ」を狙い撃ちするため、
> **ビルドを実行するローカル PC の OS / Python バージョンに左右されない**。

### 用語ミニ例（CPython / implementation / wheel / platform）

- **CPython**: `python.org` 標準の Python 実装（`python3` で動く普通のやつ）。別実装に PyPy（JIT で高速）/
  Jython（JVM）/ IronPython（.NET）がある。**Azure Functions は CPython** で動く。
- **`--implementation cp`**: wheel の「**どの Python 実装向けか**」のタグ。`cp`=CPython、`py`=実装非依存
  （純 Python）。`--python-version 3.13` と合わさり **`cp313`**（CPython 3.13 専用）を選ぶ。
- **wheel / platform の実例**: 同じ `psycopg-binary 3.3.4`・同じ CPython 3.13 向けでも、**OS / CPU 別に
  wheel が分かれている**（PyPI 実測）。我々はこの中から **Linux / glibc / x86_64** の 1 個だけを取る:

  | OS / CPU | platform タグ | 取得対象 |
  |---|---|---|
  | Windows x64 | `win_amd64` | |
  | macOS Intel / Apple Silicon | `macosx_10_13_x86_64` / `macosx_11_0_arm64` | |
  | **Linux(glibc) x86_64** | **`manylinux2014_x86_64`** | ✅ **これ** |
  | Linux(glibc) ARM | `manylinux_2_28_aarch64` | |
  | Linux(musl / Alpine) | `musllinux_1_2_x86_64` ほか | |

  → `--platform manylinux2014_x86_64 --implementation cp --python-version 3.13` は、上記の中から
  **「Linux / glibc / x86_64 / CPython3.13」の wheel 1 個を狙い撃ち**する指定。Azure Functions Linux が
  まさにこの環境なので、これを zip 同梱すれば**手元 OS に関係なく**そのまま動く。

ビルドした zip は**日付サフィックス**を付けて、**踏み台 VM 上から** `az storage blob upload --auth-mode login` で
`deployments` コンテナへアップロードし、その blob 名で `func_package_name` を更新して apply する（apply はローカル可）:

```bash
# 例: ビルドした成果物 api-20260616.zip を踏み台 VM からアップロード後
terraform -chdir=terraform/envs/spoke-subscription apply \
  -var 'func_package_name=api-20260616.zip'
# (恒久運用では tfvars に func_package_name を書いて管理してもよい)
```

- **Terraform は zip を upload しない**（ファイルを参照せず blob 名だけを使う）。ビルド済み zip のローカル配置は不要。
- `func_package_name` を変えるたびに `WEBSITE_RUN_FROM_PACKAGE` が更新 = **自動再起動**で反映。ロールバックは
  前の日付 zip 名に戻して apply。

## バージョン管理方針（ランタイム / 依存パッケージ）

> 調査・更新時点: 2026-06-15。ホスティングは **EP1（Elastic Premium）**（`terraform/modules/function_app` の
> `service_plan_sku` 既定 `EP1`）。Premium プランのため Linux Consumption の「Python 3.12 上限」制約は
> **非該当**で、Functions v4 で **Python 3.13 まで利用可**。
> **本リポジトリは「Functions で使える最新」へ全面更新済み**（Python 3.13 ＋ azure-functions 2.x セット）。

### 現状バージョン（= 最新化済み）

| 項目 | 設定値 | 最新 | 要求 Python | EOL / 備考 |
|---|---|---|---|---|
| Python ランタイム | **3.13** | 3.14（ただし下記） | – | 3.13 EOL = 2029-10-31（サポート最長）。Functions で使えるのは 3.13 まで |
| `azure-functions` (v2 SDK) | `~=2.1.0` | **2.1.0** (2026-04-13) | **>=3.13** | メジャー更新。Python 3.13 へ移行済みのため採用可 |
| `psycopg[binary]` | `~=3.3.4` | 3.3.4 (2026-05-01) | >=3.10 | 3.13 対応。cp313 manylinux wheel あり |
| `azure-identity` | `~=1.25.3` | 1.25.3 (2026-03-13) | >=3.9 | 問題なし。低リスク |

いずれも調査時点（2026-06-15）の **PyPI 最新パッチ**を floor にピン留め済み。

**バージョン制御方針 — `~=`（compatible release）で「マイナー固定・パッチのみ自動更新」**:

- `azure-functions~=2.1.0` は `>=2.1.0, ==2.1.*` と等価。`2.1.x` のパッチは `pip` が自動で拾うが、
  `2.2` 以降のマイナー / メジャーには**上がらない**（破壊的変更の自動混入を防止）。
- floor を**現行最新パッチ**に置くことで「**可能な限り最新 ＋ パッチのみ自動更新**」を実現する。
- マイナー / メジャー更新は floor を**意図的に引き上げて**実施する（例: `~=2.1.0` → `~=2.2.0`）。
  Dependabot / Renovate を使うと、新マイナー/メジャー時に floor 引き上げの PR が自動で起票される。

### Python サポート状況（Azure Functions v4 / EP1）

- Functions v4 が GA サポートする Python: **3.10 / 3.11 / 3.12 / 3.13**。EP1（Premium）なので **3.13 可**。
- **3.14 はリリース済み（2025-10）だが Functions ランタイム未対応** → 現時点で採用不可。
  「Python の最新 = 3.14」だが「Functions で使える最新 = 3.13」である点に注意（= 本リポジトリは 3.13 を採用）。
- 各 Python の EOL: 3.10=2026-10-31（EOL 間近）/ 3.11=2027-10-31 / 3.12=2028-10-31 / 3.13=2029-10-31 / 3.14=2030-10-31。

### 依存関係（バージョンの結びつき）

- **`azure-functions 2.x` ⇔ `Python 3.13+`**: 2.x は Python 3.13 以上必須。本リポジトリは Python 3.13 へ
  移行済みのため 2.x を採用できる（3.11 のままだと `pip` は要求 Python を尊重して 1.x 止まりになる）。
- **Python のバージョンは 3 箇所で一致させる（すべて 3.13 に更新済み）**:
  1. `terraform/modules/function_app/variables.tf` の `python_version`（既定 `3.13`）— 実行時ランタイム
  2. 本 README の zip ビルド手順の `--python-version 3.13` — wheel 取得対象
  3. wheel の platform tag（`manylinux2014_x86_64` + `--implementation cp` → cp313）
- **`host.json` の `version` / `extensionBundle.version`**（いずれも現状維持で OK）:
  - 最上位 `"version": "2.0"` は **host.json（ホスト設定）のスキーマ版**。*設定ファイルのフォーマット版*で
    あって、ランタイム版（Functions v4）とは**別物**。Functions v2/v3/v4 はいずれも host.json スキーマ `2.0`
    を使うため、`"2.0"` のままで正しい。
  - `extensionBundle` は**トリガー/バインディング拡張（実体）をまとめて自動取得する仕組み**。Python など
    非 .NET 言語では個別の拡張（NuGet）を管理せずこのバンドルで解決するのが標準。
    `id = Microsoft.Azure.Functions.ExtensionBundle`。
  - `version: "[4.*, 5.0.0)"` は**区間記法**（`[` =以上 / `)` =未満）→「**4.x 系の最新を使い 5.0.0 は含まない**」。
    ランタイム **v4 にはバンドル v4** を合わせる。本リポジトリは HTTP トリガーのみ（PostgreSQL は psycopg で
    直接接続）なので実質 HTTP バインディング用。現状維持でよい。
- v2 モデルのため `AzureWebJobsFeatureFlags=EnableWorkerIndexing`（`function.tf`）。新しいランタイムでは
  既定で有効だが、残置しても害はない。

### 既デプロイ済みリソースの更新手順（3.11 → 3.13 マイグレーション）

既に Function App をデプロイ済みの場合、コード更新後に実リソースへ反映する。Linux Function App の
Python 版変更は `linux_fx_version`（`PYTHON|3.11` → `PYTHON|3.13`）の **in-place 更新**で、リソース再作成は
発生しない（apply 時にアプリが再起動される）。

1. **事前確認**: `service_plan_sku=EP1`（Premium）であること、対象リージョンで Python 3.13 が提供されている
   ことを確認（`az functionapp list-runtimes --os linux` で Functions v4 / python 3.13 を確認）。
2. **コード更新を取り込む**: 本コミット（`python_version=3.13`・`requirements.txt`・ビルド手順）を反映。
3. **zip を 3.13 wheel で再ビルド**: 上記「zip のビルド手順」を `--python-version 3.13` で実行し、
   `api.zip` を作り直す（cp313 / manylinux2014 wheel を取得）。
4. **plan で差分確認**: `terraform -chdir=terraform/envs/spoke-subscription plan`。
   - `site_config.application_stack.python_version: "3.11" -> "3.13"`（= `linux_fx_version` in-place 更新）
   - run-from-package blob 名が新ハッシュ（`filemd5`）に変わり、`WEBSITE_RUN_FROM_PACKAGE` が更新される
   - **Function App や Plan が `destroy/replace` になっていないこと**を必ず確認する。
5. **apply**: `terraform -chdir=terraform/envs/spoke-subscription apply`。ランタイム変更でアプリが再起動する。
6. **疎通確認（閉域のまま）**: AKS のクライアント Pod から Function キー経由で `POST /api/customers/search` を叩き、
   200 と期待レスポンスを確認。続けて PostgreSQL（MSI/AAD トークン）への接続が成功していることをログで確認。
7. **ロールバック**: 問題があれば `python_version` と `requirements.txt` を元に戻し、旧 wheel で zip を再ビルド →
   再 apply（同じく in-place で 3.11 へ戻る）。
8. **注意（メジャー更新）**: `azure-functions 1.x → 2.x` はメジャー更新。可能なら本番前に非本番環境
   （または別スロット）で v2 デコレーター API と Python worker の互換性を検証してから本番反映する。

### 監視 / 継続運用

- ピン留めは **`~=`（マイナー固定・パッチのみ自動更新）** を維持。マイナー/メジャー化は floor を意図的に
  引き上げて実施し、Dependabot / Renovate で更新 PR を運用する。
- ランタイム版は**一元管理**: `python_version` を変えるときは必ずビルドの `--python-version` と一致させる。
- Python と各パッケージの EOL / リリースを四半期ごと（または Dependabot）で定期確認する。

### 更新時に直す箇所（チェックリスト）

- [ ] `terraform/modules/function_app/variables.tf` の `python_version`（または env の tfvars で上書き）
- [ ] 本 README の zip ビルド手順 `--python-version`
- [ ] リポジトリルート `README.md` の zip ビルド手順 `--python-version`
- [ ] `src/requirements.txt` の各ピン（必要なら上下限を見直し）
- [ ] 再ビルド → `terraform -chdir=terraform/envs/spoke-subscription apply` → 疎通確認

## 参考（不採用）: GitHub Actions で zip ビルド & 配置（CI 例）

> ⚠️ **本リポジトリでは CI/CD 自動化は恒久的に採用しない**（デプロイは社内踏み台 Portal からの手動アップロード +
> `terraform apply`）。以下は過去検討の参考であり、**現行の運用ではない**。さらに、成果物 Storage は
> 現在 **共有キー無効 + 社内踏み台 IP のみ許可**のため、GitHub ホスト型ランナー（公開 IP・流動的）からは到達できない。
> 例中の「Storage は公開 + SAS」「blob 名 = filemd5」は**現行モデルと異なる**（現行は SAS 廃止・blob 名は `func_package_name` 指定）。

手元で実行している「**zip ビルド → `terraform apply`**」は CI へ載せられる。
（参考）GitHub ホスト型ランナー（`ubuntu-latest`）で完結する想定だった構成:

- **wheel ビルドはネット上のランナーで OK**: `--platform`/`--python-version`/`--implementation` で
  Linux/cp313 wheel を取得するため、ランナーの OS / Python 版に依存しない（[用語ミニ例](#用語ミニ例cpython--implementation--wheel--platform) 参照）。
- **配置先 Storage は公開可**（`public_network_access_enabled = true` ＋ SAS）なので、ランナーから
  blob をアップロードできる。**Function App 自体は閉域**（`public_network_access_enabled = false`）だが、
  デプロイは **ARM コントロールプレーン（公開）** 経由で行われ、Function 起動時に Function 側が
  `WEBSITE_RUN_FROM_PACKAGE`（SAS 付き blob URL）から package を取得するため、CI が Function の閉域内へ
  入る必要は無い。
- ⚠️ **将来デプロイ Storage も閉域化**（`public_network_access_enabled = false`）した場合は、ランナーから
  blob data plane に到達できなくなるため、**VNet 内の self-hosted runner**（または private networking 経由）が必要。
- ⚠️ **state**: 本 env は現状 backend ブロック未設定＝**ローカル state**。CI 運用では競合や紛失を避けるため
  **azurerm リモートバックエンド**（Storage コンテナ）への移行を推奨。

### 認証（OIDC・推奨）

シークレットレスな **OIDC フェデレーション資格情報**を使う（Entra アプリ登録に GitHub の
`repo:OWNER/REPO:ref:refs/heads/BRANCH` 等のフェデレーション資格情報を登録し、サブスクリプションに
必要ロール = Contributor 等を付与）。GitHub 側 Secrets/Variables に `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` /
`AZURE_SUBSCRIPTION_ID` を設定。

### ワークフロー例 `.github/workflows/deploy-function.yml`

```yaml
name: deploy-function

on:
  workflow_dispatch:        # 手動実行
  push:
    branches: [ main ]
    paths:                  # Function アプリのソース変更時のみ
      - 'terraform/envs/spoke-subscription/files/function_app/customer_search/src/**'
      - 'terraform/modules/function_app/**'
      - '.github/workflows/deploy-function.yml'

permissions:
  id-token: write           # OIDC で azure/login するため必須
  contents: read

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    env:
      APP_DIR: terraform/envs/spoke-subscription/files/function_app/customer_search
      TF_DIR:  terraform/envs/spoke-subscription
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: '3.13'   # pip 実行用 (wheel 選定は --python-version で固定するため必須ではない)

      # (1) 依存込みで api.zip をビルド (= 本 README「zip のビルド手順」と同一)
      - name: Build api.zip
        run: |
          set -euo pipefail
          OUT="$GITHUB_WORKSPACE/$APP_DIR/api.zip"
          SRC="$GITHUB_WORKSPACE/$APP_DIR/src"
          BUILD="$(mktemp -d)"
          cp -r "$SRC"/. "$BUILD"/
          pip install --target "$BUILD/.python_packages/lib/site-packages" \
            --only-binary=:all: --platform manylinux2014_x86_64 \
            --python-version 3.13 --implementation cp \
            -r "$SRC/requirements.txt"
          rm -f "$OUT"
          ( cd "$BUILD" && zip -qr "$OUT" . )
          rm -rf "$BUILD"
          echo "built: $OUT"

      # (任意) 成果物を artifact 保存
      - uses: actions/upload-artifact@v4
        with:
          name: api-zip
          path: ${{ env.APP_DIR }}/api.zip

      # (2) Azure 認証 (OIDC)
      - uses: azure/login@v2
        with:
          client-id:       ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      # (3) Terraform で blob アップロード & デプロイ (閉域のまま)
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: '1.15.5'   # providers.tf の required_version に合わせる

      - name: Terraform apply
        working-directory: ${{ env.TF_DIR }}
        env:
          ARM_USE_OIDC:        'true'
          ARM_CLIENT_ID:       ${{ secrets.AZURE_CLIENT_ID }}
          ARM_TENANT_ID:       ${{ secrets.AZURE_TENANT_ID }}
          ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          TF_VAR_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
        run: |
          terraform init
          terraform apply -auto-approve
```

- **再デプロイ条件**: blob 名は zip の `filemd5` を含むため、**zip の中身が変わったときだけ**再アップロード・
  再デプロイされる（依存やソースが不変なら no-op）。
- **検証**: apply 後に AKS クライアントから Function キー経由で `POST /api/customers/search` → 200、
  続けて PostgreSQL(MSI) 疎通をログで確認（[既デプロイ済みリソースの更新手順](#既デプロイ済みリソースの更新手順311--313-マイグレーション) と同じ観点）。

## 参考: 完全閉域での配置パターン（選択肢の整理）

> **現行コードの裏側 Storage は完全閉域**（`public_network_access_enabled = false` + **blob/queue/table の Private Endpoint** +
> **共有キー無効** + Entra RBAC）。アップロードは **Hub 踏み台 VM** から PE 経由で行い（`blob` ゾーンを Hub にもリンクし、
> PE サブネットの NSG で `snet-jumpbox` を許可）、Function は AzureWebJobsStorage / run-from-package を MI + PE で読む。
> 以下は配置手段の選択肢の整理（参考）。本リポジトリは下表 **A 相当（VNet 内側＝踏み台 VM 起点）** を採用している。

### 前提：Storage を Private 化するとセットで要る変更

- 裏側 Storage を `public_network_access_enabled = false` にするだけでは、**Function が起動時に
  `WEBSITE_RUN_FROM_PACKAGE`（blob URL）を取得できず起動不可**になる。`func_integration` サブネットには
  `Microsoft.Storage` サービスエンドポイントも Storage 用 PE も無いため。
- よって Storage 閉域化は **「Storage 用 Private Endpoint ＋ `privatelink.blob.core.windows.net` の Private DNS」
  追加とセット**で行う（Function の取得経路を private に張り替える）。

### 配置手段の選択肢（完全閉域時）

| 選択肢 | 概要 | 追加インフラ | CD 自動化 |
|---|---|---|---|
| A. 内側エージェント | VNet 内の self-hosted runner / AKS の ARC で `terraform apply` | 要（常駐 or オンデマンド） | ◎ 完全自動 |
| **B. Cloud Shell ＋ Bastion ＋ VM（本項）** | Cloud Shell で zip ビルド → Bastion 経由で VM へ持ち込み → VM から Storage 配置 | 踏み台 VM（既存流用可） | △ 手動（last mile） |
| C. ホステッド＋Storage 公開維持 | Storage だけ Public のまま GitHub ホステッドでデプロイ | 不要 | ◎ だが**完全閉域ではない** |

### パターン B：Cloud Shell でビルド → Bastion 経由 VM → Storage 配置

ビルドはインターネット可の **Azure Cloud Shell**（VNet 外）で行い、**配置だけ閉域内側の VM から**実行する。

1. **Cloud Shell で zip をビルド**（Cloud Shell はネット可なので PyPI から直接 wheel 取得 = 依存問題なし）。
   本 README「[zip のビルド手順](#zip-のビルド手順)」と同じコマンドで `api.zip` を作る。
2. **zip を取り出す**：Cloud Shell の `download api.zip` でローカルへ落とす（またはアーティファクト経由）。
3. **Bastion 経由で VNet 内 VM へ持ち込む**：Bastion のファイル転送（ネイティブクライアント）や
   `az network bastion tunnel` ＋ `scp` で、`api.zip` を踏み台 VM へアップロードする。
   - VM は **Spoke VNet 内**で、Storage の **Private Endpoint（`privatelink.blob.core.windows.net`）**に到達できること。
   - VM にはユーザー割り当て/システム MI を付け、対象 Storage に `Storage Blob Data Contributor` を付与（共有キー無効化と相性良）。
4. **VM から Storage へ配置**。素の blob アップロードは **blob 名＝`filemd5` ハッシュ**と
   `WEBSITE_RUN_FROM_PACKAGE` の整合崩れに注意（[再デプロイ条件](#参考-github-actions-で-zip-ビルド--配置ci-例) と同様）。**安全策は VM 上で `terraform apply` を実行**し、
   blob アップロード（ハッシュ名）とアプリ設定更新を Terraform に一貫管理させること:
   ```bash
   # VM (閉域内側) 上で
   #   api.zip を terraform/envs/spoke-subscription/files/function_app/customer_search/ に配置済みにしてから
   terraform -chdir=terraform/envs/spoke-subscription apply
   ```
   - 手動 `az storage blob upload` を使う場合は、blob 名を `api-<filemd5先頭12桁>.zip` に合わせ、
     `WEBSITE_RUN_FROM_PACKAGE`（ARM 経由・公開なのでどこからでも可）も同じ blob 名に更新する。
5. **疎通確認**：AKS クライアントから Function キー経由で `POST /api/customers/search` → 200、PostgreSQL(MSI) 疎通。

> 妥協点：このパターンは **デプロイの last mile（配置）が手動・内側起点**になる（＝完全 CD ではない）。
> 完全自動化したくなったら選択肢 A（内側エージェント）へ移行する。Storage を公開のまま許容できるなら C。

## Links

### Azure Functions / ランタイム

- [Azure Functions Python developer guide](https://learn.microsoft.com/azure/azure-functions/functions-reference-python)
- [Python v2 programming model（デコレーター方式）](https://learn.microsoft.com/azure/azure-functions/functions-reference-python#programming-model)
- [Supported languages / runtime versions](https://learn.microsoft.com/azure/azure-functions/supported-languages)
- [Language runtime support policy（Python サポート版）](https://learn.microsoft.com/azure/azure-functions/language-support-policy)
- [Premium plan（Elastic Premium / EP1）](https://learn.microsoft.com/azure/azure-functions/functions-premium-plan)
- [Run from package（WEBSITE_RUN_FROM_PACKAGE）](https://learn.microsoft.com/azure/azure-functions/run-functions-from-deployment-package)
- [Deployment technologies / リモートビルド・Oryx（SCM_DO_BUILD_DURING_DEPLOYMENT）](https://learn.microsoft.com/azure/azure-functions/functions-deployment-technologies)
- [Extension bundles（host.json extensionBundle）](https://learn.microsoft.com/azure/azure-functions/functions-bindings-register)
- [`az functionapp list-runtimes`（提供ランタイム確認）](https://learn.microsoft.com/cli/azure/functionapp#az-functionapp-list-runtimes)

### 依存パッケージ

- `azure-functions`: [PyPI](https://pypi.org/project/azure-functions/) / [GitHub](https://github.com/Azure/azure-functions-python-library)
- `psycopg` (psycopg3): [PyPI](https://pypi.org/project/psycopg/) / [Docs](https://www.psycopg.org/psycopg3/docs/)
- `azure-identity`: [PyPI](https://pypi.org/project/azure-identity/) / [Docs](https://learn.microsoft.com/python/api/overview/azure/identity-readme)

### Python バージョン / EOL

- [Python release & EOL（公式 devguide）](https://devguide.python.org/versions/)
- [endoflife.date / Python](https://endoflife.date/python)

### CI / GitHub Actions

- [azure/login（OIDC ログイン）](https://github.com/Azure/login)
- [GitHub Actions の OpenID Connect（Azure フェデレーション資格情報）](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)
- [hashicorp/setup-terraform](https://github.com/hashicorp/setup-terraform)
- [Terraform azurerm backend（リモート state）](https://developer.hashicorp.com/terraform/language/settings/backends/azurerm)
