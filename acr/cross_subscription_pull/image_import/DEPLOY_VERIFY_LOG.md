# image_import デプロイ・検証ログ

実際に Azure へデプロイし、`az acr import` でサブスク A(private ACR) → B(private ACR) の
クロスサブスクリプション import が想定通り動くかを検証した記録。

## 環境・前提（preflight）

- 日時: 2026-06-26
- terraform: v1.15.5 / azure-cli: 2.84.0
- ログイン: <AZURE_LOGIN_USER> (user)
- サブスクリプション（**同一テナント** `<TENANT_ID>`）:
  - A (ソース) = `従量課金2` / `<SUBSCRIPTION_A_ID>`
  - B (取り込み先) = `従量課金` / `<SUBSCRIPTION_B_ID>`
- → 同一テナントのため `az acr import`（trusted services 経由）が public 無効同士でも成立する条件を満たす。

検証フロー: `to`(B) apply → principal_id を `from`(A) へ → `from` apply → A にサンプル投入 → A→B import → B で確認。

---

## 1. デプロイ

### to (B) を apply（先）
```
$ cd image_import/to && terraform init && terraform apply -auto-approve
Apply complete! Resources: 4 added.   # RG / UAMI / Premium ACR / role assignment
Outputs:
  runner_identity_principal_id = <RUNNER_PRINCIPAL_ID>
  runner_identity_client_id    = <RUNNER_CLIENT_ID>
  target_acr_name              = acrimporttargetacrxxx
```
→ ロール `Container Registry Data Importer and Data Reader` の付与に成功（このテナントで当該ロールが存在することを確認）。

### from (A) を apply（runner principal_id を渡して）
`from/terraform.tfvars` の `import_runner_principal_id` に上記 principal_id を設定。
```
$ cd image_import/from && terraform init && terraform apply -auto-approve
Apply complete! Resources: 3 added.   # RG / Premium ACR / role assignment(source)
Outputs:
  source_acr_id           = /subscriptions/<SUBSCRIPTION_A_ID>/.../registries/acrimportsourceacrxxx
  source_acr_login_server = acrimportsourceacrxxx.azurecr.io
```

### ACR ネットワーク設定の実機確認
```
Name                   Sku      PublicAccess  Bypass
acrimportsourceacrxxx  Premium  Disabled      AzureServices   # A
acrimporttargetacrxxx  Premium  Disabled      AzureServices   # B
```
→ 両 ACR とも **完全プライベート（public 無効）+ allow trusted services** で稼働。

## 2. 検証

### (準備) A にサンプルイメージ投入：public mcr → private A
```
$ az acr import --name acrimportsourceacrxxx --subscription <A> \
    --source mcr.microsoft.com/hello-world:latest --image hello-world:latest
exit=0   # private な ACR への import 投入も成立（コントロールプレーン操作）
```

### (本命) クロスサブスク import：A(private) → B(private)
```
$ az acr import --name acrimporttargetacrxxx --subscription <B> \
    --source hello-world:latest --image hello-world:latest \
    --registry /subscriptions/<A>/.../registries/acrimportsourceacrxxx
exit=0   # ★ 成功。両 ACR public 無効・同一テナント・trusted services 経由で import 成立
```

### データプレーン確認の注意点（想定どおりの制約）
- `az acr repository list` 等は **データプレーン**操作。private(public 無効) ACR へは VNet/PE が無いと届かず 403。
- さらに `Owner` でもデータプレーン読み取り（`AcrPull` 等の dataAction）は持たないため、外部からの直接 list は不可。
- → これは ACR の private 設計上の**正しい挙動**。実運用では VNet 内 / PE 経由 / `AcrPull` 保有 ID で参照する。

### イメージ存在の確定確認（非侵襲）
`--force` なしの再 import は既存タグに対し Conflict エラーを返す性質を利用：
```
$ az acr import --name acrimporttargetacrxxx --subscription <B> \
    --source hello-world:latest --image hello-world:latest --registry <A の resource ID>
ERROR: (Conflict) ... Tag hello-world:latest already exists in target registry.
```
→ **B にイメージが確実に存在することを確認**。

## 3. 結論

- **想定どおり動作**：両 ACR が `public_network_access_enabled=false`（完全プライベート）でも、
  同一 Entra テナント + `allow trusted services`（`network_rule_bypass_option="AzureServices"`）+ ソースを
  resource ID 指定、で **クロスサブスク import が成功**した。
- VNet / Private Endpoint / VNet ピアリング / VM は **一切不要**で目的を達成（= `image_pull_push` は不要だった、の実証）。
- データプレーン参照（repository list 等）だけは private のため到達制約あり（設計どおり）。

## 4. 後片付け（コスト発生中：Premium ACR ×2）

検証リソースは課金されるため、不要なら destroy する：
```
cd image_import/from && terraform destroy -auto-approve
cd image_import/to   && terraform destroy -auto-approve
```
（A の role assignment が B の UAMI に依存するため from→to の順で destroy 推奨）
