# Premium / 単一 AZ の Azure Cache for Redis を作成する

親ディレクトリのゾーン変更検証 ([../README.md](../README.md)) を、
**作成可能な別環境で実施する**ための最小構成。

## 前提: 作成できるサブスクリプションかを先に確認する

Azure Cache for Redis は退役が進行しており、**過去に作成実績が無いサブスクリプションでは
新規作成が RP 側でブロックされる** (`400 BadRequest: Azure Cache for Redis is retiring`)。

```bash
../check-history.sh            # 組織での過去の作成履歴を調べる (読み取り専用)
../check-eligibility.sh <SUB_ID> <RG>   # 作成可否を確定させる
```

詳細は [../creation-eligibility.md](../creation-eligibility.md) を参照。

## 構成

| リソース | 内容 |
|----------|------|
| `redissaz-rg` | リソースグループ |
| `redis-redissaz-<suffix>` | Azure Cache for Redis **Premium P1** / replica 1 / **単一 AZ** |

- **Premium を使う理由**: `zones` でゾーン番号を明示指定できるのは Premium のみ。
  Standard は Azure の自動割り当て (`Automatic`) 固定で、ゾーンを選べない。
- **public endpoint 構成**: VNet インジェクションを使うと、後から
  `zonalAllocationPolicy = Automatic` への in-place 変更ができなくなるため
  (親ディレクトリの検証で回避策を試せるようにしている)。

## 使い方

```bash
cp terraform.tfvars.sample terraform.tfvars   # subscription_id を記入
terraform init
terraform apply                                # Premium の作成は 20〜30 分ほど

terraform output redis_hostname
terraform output -raw redis_primary_access_key
```

### 後片付け

```bash
terraform destroy
```

Premium は課金が続くため、検証が終わったら必ず destroy すること。

## ゾーンを変更すると再作成になる

```bash
terraform plan -var zone=2
```

`zones` は azurerm の **ForceNew 属性**なので、`-/+ destroy and then create replacement`
になる。これは provider の都合ではなく、ARM の Update API に `zones` フィールドが
存在しないため (根拠は [../research.md](../research.md))。

**再作成で何が起きるかは [../doc/recreation-impact.md](../doc/recreation-impact.md) にまとめてある。**
ホスト名は変わらないがアクセスキーは変わる、ダウンタイムが発生する、など
事前に把握しておくべき点がある。

## ファイル

| ファイル | 内容 |
|----------|------|
| `providers.tf` | provider / version 固定 |
| `variables.tf` | `subscription_id` / `location` / `zone` / `name_prefix` / `capacity` |
| `locals.tf` | 命名・SKU などの設定値 |
| `redis.tf` | RG + Redis キャッシュ本体 |
| `outputs.tf` | ホスト名 / キー / ゾーンなど |
| `terraform.tfvars.sample` | tfvars のテンプレート |

`terraform.tfvars` は親ディレクトリの `.gitignore` により追跡対象外になる。
