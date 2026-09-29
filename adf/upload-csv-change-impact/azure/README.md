# 実機 ADF での検証

親ディレクトリのローカル模擬 (`verify.py`) で置いた前提を、実際の ADF で確かめるための構成。
変更後の `ds_src_csv` (`../datasets/ds_src_csv.after.json`) を持つ ADF を新しく構築し、
`../inputs/*.csv` を 1 ファイルずつ流して、結果をローカル模擬 (`../out/summary.json`) と突き合わせる。

## 構成するもの

| リソース | 内容 |
|----------|------|
| Resource Group `csvenc-rg` | 検証一式の入れ物 (japaneast) |
| Storage Account `csvencst<suffix>` | `upload` / `archive` コンテナ。作業端末の IP のみ許可。ADF / az CLI は Entra ID (RBAC) でアクセス |
| PostgreSQL Flexible Server `csvenc-psql-<suffix>` | B1ms / v16 / DB `appdb`。public access + ファイアウォール (Azure サービス / 作業端末 IP) |
| Data Factory `csvenc-adf-<suffix>` | Linked Service `ls_blob` (MI) / `ls_psql` (Basic)、Dataset 6 個、Pipeline `pl_csv_ingest` |

次のファイルは**本番のものを直接読む**ので、本番側を直すとこの構成にも反映される。

- `pipeline.json` / `queries/validation.sql` / `ds_src_csv` 以外の Dataset 定義 (本番 hub env の `files/adf_pipeline/customer_info_registration/`)
- `create-tables.sql` (`setup-db.sh` が使う。末尾の AAD ロールへの GRANT は除く)

`ds_src_csv` だけは `var.src_csv_dataset` に従い、`../datasets/ds_src_csv.after.json` (既定) か
`ds_src_csv.before.json` を使う。

### 本番との違い

確かめたいのは Dataset の読み込み挙動だけなので、ネットワークと認証は簡略化している。

| 項目 | 本番 | この構成 |
|------|------|----------|
| ADF のネットワーク | Managed VNet + Managed Private Endpoint | AutoResolveIntegrationRuntime (public) |
| PostgreSQL への接続 | Private Endpoint + ADF の MI (Entra 認証) | public + ファイアウォール + Basic 認証 |
| パイプラインの起動 | Blob Event Trigger (`trg_csv_uploaded`) | `run_adf.py` が手動実行 (`triggeredFileName` を渡す) |

トリガーからパイプラインに渡るのは `triggeredFileName` だけなので、手動実行でもパイプラインへの入力は同じになる。

## 使い方

前提: `az login` 済み、Docker が使えること (`setup-db.sh` がコンテナの psql を使う)。

```bash
cd azure
cp terraform.tfvars.sample terraform.tfvars   # subscription_id / allowed_ip / psql_admin_password を記入
terraform init
terraform apply                               # 10〜15 分ほど (PostgreSQL の作成が長い)

./setup-db.sh                                 # テーブル作成 (パスワードを聞かれる。PGPASSWORD でも可)

(cd .. && ./run.sh)                           # ローカル模擬の結果 (../out/summary.json) を作っておく
./run_adf.py                                  # ../inputs/*.csv を順に ADF へ流して比較する
./run_adf.py ../inputs/utf8bom_crlf.csv       # 1 ファイルだけ流す場合
```

ロール割当 (Storage Blob Data Contributor) の反映には数分かかる。apply 直後に `run_adf.py` のアップロードや
ADF の Copy が 403 で失敗したら、少し待ってから再実行する。

### 変更前の挙動も実測する

同じ ADF の `ds_src_csv` を変更前の定義に差し替えて流せば、変更前の設定での挙動も実測できる。

```bash
terraform apply -var src_csv_dataset=before
./run_adf.py
```

### 出力 (`out-azure/`)

| ファイル | 内容 |
|----------|------|
| `out-azure/<dataset>__<input>/success.csv` | ArchiveSuccess が出力した CSV (最新のもの) |
| `out-azure/<dataset>__<input>/error.csv` | ArchiveError が出力した CSV (最新のもの) |
| `out-azure/<dataset>__<input>/failed.txt` | パイプラインが失敗した場合の各 activity のエラーメッセージ |
| `out-azure/<dataset>__<input>/activity_runs.json` | activity 実行結果の生データ |
| `out-azure/summary.<dataset>.json` | 全ケースの結果 |

最後に表示される `compare` 列の意味は次のとおり。

- `MATCH`: ローカル模擬と一致した。ADF が Succeeded で模擬が OK の場合は success / error の行も一致、
  ADF が InputCSV で Failed で模擬が COPY_FAILED の場合は状態が一致
- `DIFF`: ローカル模擬と一致しない。親 README の「模擬の前提」のどれかが実機と違うので、
  `failed.txt` のメッセージを見て `verify.py` の前提 (`--bom` / `--missing-column`) を合わせ直す

すべて MATCH なら終了コード 0。

## 後片付け

```bash
terraform destroy
```

PostgreSQL (B1ms) は起動している間ずっと課金されるので、検証が終わったら削除する。
