# Azure Cache for Redis の再作成 (replace) が発生したときの影響範囲

`zones` の変更などで Terraform が「破棄 -> 再作成」を計画したとき、
実際に何が変わり、何が変わらないのかを整理する。

なぜ replace になるのかは [../research.md](../research.md)、
回避できる唯一の経路 (`zonalAllocationPolicy = Automatic`) は
[../README.md](../README.md) を参照。

## 結論 (先に要点)

| 観点 | 結論 |
|------|------|
| 接続先ホスト名 | **変わらない** (キャッシュ名を変えなければ) |
| **アクセスキー** | **変わる**。ここが最大の落とし穴 |
| ARM リソース ID | 変わらない (アラート等の参照は生きる) |
| キャッシュ内のデータ | **全消失** |
| **ダウンタイム** | **発生する。目安 25〜40 分** |

**「ホスト名が同じままキーだけ変わる」** という組み合わせが最も危険。
設定ファイル上は正しく見えるのに認証だけ落ちるため、原因に気づきにくい。

そして **アプリ影響が本当にミニマムになるのは「純粋なキャッシュ用途」に限る**。
用途によっては軽微では済まない (後述)。

## 1. 接続先 (エンドポイント) は変わるか

### ホスト名: 変わらない

Azure Cache for Redis のホスト名は `<キャッシュ名>.redis.cache.windows.net` で、
**キャッシュ名から決まる**。Terraform が同じ名前で作り直す限りホスト名は同じ。

```
redis-redissaz-abc123.redis.cache.windows.net   # 再作成前
redis-redissaz-abc123.redis.cache.windows.net   # 再作成後 (同じ)
```

SSL ポート (6380) も変わらない。

> **ただし注意**: 名前に `random_string` などを混ぜている場合、
> その値が再生成されると**名前ごと変わる**。本リポジトリの構成では
> `random_string.suffix` は `keepers` を持たないため再生成されないが、
> 構成によっては巻き込まれる。plan で `name` に差分が出ていないか必ず確認すること。

### ARM リソース ID: 変わらない

```
/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Cache/redis/<name>
```

名前と RG が同じなら ID も同じ。**リソース ID で参照しているメトリックアラートや
ロール割り当ての「宛先」は生き残る**。

### 公開 IP アドレス: 変わる

クライアントは通常ホスト名で接続するため問題にならないが、
**アプリ側の egress ファイアウォールでキャッシュの IP を許可している場合は破綻する**。

### Private Endpoint 構成の場合

PE 自体も作り直しになり、**プライベート IP が変わる可能性がある**。
Private DNS ゾーンの A レコードは PE が再登録するが、
クライアント側の DNS キャッシュが切れるまでのラグに注意。

## 2. アクセスキーは変わる ★最重要

**新しいキャッシュインスタンスには新しいプライマリ / セカンダリキーが払い出される。**
再作成前のキーは一切通用しない。

影響を受けるもの:

- アプリの接続文字列 (App Service のアプリ設定、AKS の Secret、`.env` など)
- Key Vault に格納した接続文字列 / キー
- CI/CD のパイプライン変数
- 手元の検証スクリプト

### Terraform で連携している場合

`azurerm_redis_cache.this.primary_access_key` を参照して
Key Vault シークレットやアプリ設定に流し込んでいれば、**同じ apply の中で追従する**。

```hcl
resource "azurerm_key_vault_secret" "redis" {
  name         = "redis-connection-string"
  value        = azurerm_redis_cache.this.primary_connection_string
  key_vault_id = azurerm_key_vault.this.id
}
```

ただし **アプリがその値を読み直すタイミングは別問題**。
App Service のアプリ設定なら再起動、Pod なら再デプロイやシークレット再読込が要る。

### 手動で設定している場合

**apply しただけでは直らない。** 再作成後に手作業でキーを差し替えるまで、
アプリは認証エラーで接続できないままになる。

### 回避策: Entra ID 認証を使う

アクセスキーではなく Microsoft Entra ID 認証 (`azurerm_redis_cache_access_policy_assignment`)
を使っていれば、**そもそもローテーションするキーが無い**。
マネージド ID のプリンシパル ID は変わらないため、アクセスポリシー割り当てを
再作成すれば接続が復旧する。再作成の痛みを大きく減らせる。

## 3. 「揮発性データだけだから影響はミニマム」は用途次第

キャッシュ内のデータは **全消失する**。
純粋な read-through キャッシュとして使っているなら確かに影響は小さいが、
**Redis は実際にはキャッシュ以外の用途にも使われがち**で、そこが盲点になる。

| 用途 | 再作成時の影響 | 深刻度 |
|------|----------------|:---:|
| 純粋な read-through キャッシュ | 再構築されるまでミス率上昇 | 小〜中 |
| **セッションストア** | **全ユーザーがログアウト** | 大 |
| **ジョブキュー / ブローカー** (Sidekiq, Celery, Bull, RQ) | **未処理ジョブが消失** | **特大** |
| **分散ロック** (Redlock 等) | ロックが消え、二重実行の恐れ | 大 |
| レートリミットのカウンタ | カウンタがリセットされ、バースト通過 | 中 |
| 一時的な冪等性キー | 重複処理の恐れ | 中〜大 |
| Pub/Sub | 購読が切れる。永続化されないメッセージは消失 | 中 |

### キャッシュスタンピードに注意

キャッシュが空の状態でトラフィックを受けると、**全リクエストがミスして
オリジン (DB 等) に殺到する**。復旧直後にバックエンドが落ちる、という二次障害が起きうる。

対策としては、ウォームアップしてから流す / ミス時の同時実行を絞る (single-flight) /
段階的にトラフィックを戻す、など。

### データ永続化 (RDB / AOF) を設定していても自動復旧はしない

Premium のデータ永続化を有効にしていても、**新しいキャッシュは空で作られる**。
ストレージアカウントに残った RDB から戻したい場合は、作成後に明示的にインポートする。

```bash
az redis import --subscription <SUB> -g <RG> -n <NAME> \
  --files "https://<storage>.blob.core.windows.net/<container>/<dump>.rdb"
```

## 4. ダウンタイムは避けられない

### 破棄が先、作成が後

Terraform の replace は既定で **destroy -> create** の順。
Premium の作成には時間がかかるため、その間まるごと落ちる。

| フェーズ | 目安 |
|----------|------|
| 既存キャッシュの削除 | 数分 |
| Premium キャッシュの作成 | **20〜30 分** |
| 合計ダウンタイム | **25〜40 分程度** |

> 作成時間は一般的な目安。本リポジトリの検証環境では新規作成がブロックされていたため
> 実測はできていない ([../creation-eligibility.md](../creation-eligibility.md))。

### `create_before_destroy` は使えない

「先に新しいのを作ってから古いのを消す」でダウンタイムを消したくなるが、
**キャッシュ名はグローバル一意の DNS 名**なので、同名の 2 台目を作れず失敗する。

```hcl
lifecycle {
  create_before_destroy = true   # 同名では作成できずエラーになる
}
```

名前を変えれば同時に立てられるが、その場合は **ホスト名が変わる**ので
「接続先は変わらない」という前提が崩れる。どちらかを選ぶことになる。

### ダウンタイムを避けたいなら replace を回避する

ゾーン冗長化が目的なら、**再作成せずに `zonalAllocationPolicy = Automatic` へ
in-place 更新する経路がある**。ゾーン番号を選べない / 不可逆という制約はあるが、
ダウンタイムは発生しない。詳細は [../README.md](../README.md) と
[../research.md](../research.md) を参照。

## 5. その他の懸念点

### 子リソースが巻き込まれる

キャッシュに紐づくものは一緒に消え、作り直しになる。
Terraform で管理していれば追従するが、**手動で作ったものは復旧されない**。

- `azurerm_redis_firewall_rule` — ファイアウォール規則
- `azurerm_redis_cache_access_policy` / `..._assignment` — Entra ID アクセスポリシー
- `azurerm_monitor_diagnostic_setting` — 診断設定 (**ログの連続性が途切れる**)
- Private Endpoint 接続

### ジオレプリケーションはリンク解除が先に必要

`azurerm_redis_linked_server` でジオレプリケーションを組んでいる場合、
**リンクされたままのキャッシュは削除できない**。
Terraform の依存関係で解除が先に走るはずだが、plan で順序を必ず確認すること。

加えて、**ジオレプリケーション構成のキャッシュは
`zonalAllocationPolicy = Automatic` への in-place 変更も非対応**なので、
ゾーン冗長化したい場合の選択肢がほぼ無くなる。

### 予約インスタンス (Reserved Capacity)

予約は「SKU + リージョン」に対して適用されるため、
同じ SKU で作り直す限り引き続き適用される。実害は小さい。

### 監視・アラート

リソース ID が同じなのでアラートルールの宛先は生きるが、
**破棄〜作成の間はメトリックが途切れ、可用性アラートが発報する**。
計画的な作業ならメンテナンス期間として抑制しておくこと。

### Terraform の巻き込み範囲

キャッシュの属性を参照している他リソースも更新対象になる。
plan で「どこまで波及するか」を必ず確認する。

```bash
terraform plan -var zone=2
terraform plan -var zone=2 -out=tf.plan && terraform show -json tf.plan \
  | jq -r '.resource_changes[] | select(.change.actions[0] != "no-op")
           | "\(.change.actions|join(","))  \(.address)"'
```

## 6. 実施するときのチェックリスト

- [ ] plan で `name` に差分が出ていないか (出ていればホスト名が変わる)
- [ ] plan で波及範囲を確認したか (上記 jq)
- [ ] アクセスキーの参照元をすべて洗い出したか (Key Vault / アプリ設定 / CI/CD / 手元)
- [ ] Redis の用途を確認したか (セッション / キュー / ロックが乗っていないか)
- [ ] キューが乗っている場合、事前にドレインしたか
- [ ] 25〜40 分のダウンタイムを確保したか。メンテナンス告知は済んだか
- [ ] 監視アラートを抑制したか
- [ ] 復旧後のキャッシュスタンピード対策 (ウォームアップ / 段階的投入) を用意したか
- [ ] 永続化データを戻す必要があるか。戻すなら RDB インポート手順を用意したか
- [ ] ジオレプリケーションのリンク解除順序を確認したか
- [ ] **そもそも replace を避けられないか** を検討したか
      (`zonalAllocationPolicy = Automatic` / Entra ID 認証への移行)
