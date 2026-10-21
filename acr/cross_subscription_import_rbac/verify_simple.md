# 簡易確認 — test-user-01 でクロスサブスクリプション import

現状（ソース ACR に test-user-01 の `Container Registry Data Importer and Data Reader` 付与済み、サブスク B は Owner）で **import が成功する** 想定。
詳細な検証項目は [VERIFY.md](VERIFY.md)。

## 1. test-user-01 でログイン（専用ターミナルで実行）

管理者（miumosh）のログイン状態を壊さないよう、このターミナルだけ設定ディレクトリを分ける。

```bash
export AZURE_CONFIG_DIR=~/.azure-test-user-01
az login --tenant <TENANT_ID> --use-device-code
az account show --query user.name -o tsv
# => test-user-01@<tenant>.onmicrosoft.com
```

## 2. import 実行（成功するはず）

```bash
az acr import \
  --name acrimprbacdst1ext0m \
  --subscription <SUB_B_ID> \
  --registry /subscriptions/<SUB_A_ID>/resourceGroups/acr-import-rbac-a-rg/providers/Microsoft.ContainerRegistry/registries/acrimprbacsrc1ext0m \
  --source hello-world:latest \
  --image step1/hello-world:latest
```

成功時は何も出力されずに終了する（終了コード 0）。

## 3. 結果確認（同じターミナルで OK）

両 ACR とも public 無効のため `az acr repository show-tags` は 403 になる。アクティビティログで確認する。

```bash
az monitor activity-log list \
  --resource-id /subscriptions/<SUB_B_ID>/resourceGroups/acr-import-rbac-b-rg/providers/Microsoft.ContainerRegistry/registries/acrimprbacdst1ext0m \
  --offset 1h \
  --query "[?operationName.value=='Microsoft.ContainerRegistry/registries/importImage/action'].{who:caller,status:status.value,time:eventTimestamp}" \
  -o table
```

`who` が test-user-01 で `Started` / `Accepted` の 2 行が出れば、ARM の RBAC チェックは通っている。
import は非同期処理（202 Accepted）のため、`Succeeded` の行は記録されない。完了したかどうかは、`az acr import` がエラーなしで終わったことで判断する（CLI は完了まで待ち、失敗時はエラーを表示する）。

取り込み先にタグがあることを確かめたい場合は、取り込み先の中で import し直す（ARM 経由なので public 無効でも可。タグが無ければ `Unable to find manifest digest` で失敗する）。

```bash
az acr import \
  --name acrimprbacdst1ext0m \
  --subscription <SUB_B_ID> \
  --registry /subscriptions/<SUB_B_ID>/resourceGroups/acr-import-rbac-b-rg/providers/Microsoft.ContainerRegistry/registries/acrimprbacdst1ext0m \
  --source step1/hello-world:latest \
  --image verify/step1-exists:latest
```

## 4.（任意）ソースのロールを外して失敗することを確認

**管理者のターミナル**（`AZURE_CONFIG_DIR` を設定していない方）で実行:

```bash
az role assignment delete \
  --assignee <OPERATOR_OBJECT_ID> \
  --role "Container Registry Data Importer and Data Reader" \
  --scope /subscriptions/<SUB_A_ID>/resourceGroups/acr-import-rbac-a-rg/providers/Microsoft.ContainerRegistry/registries/acrimprbacsrc1ext0m
```

5 分ほど待ってから、**test-user-01 のターミナル**で:

```bash
az acr import \
  --name acrimprbacdst1ext0m \
  --subscription <SUB_B_ID> \
  --registry /subscriptions/<SUB_A_ID>/resourceGroups/acr-import-rbac-a-rg/providers/Microsoft.ContainerRegistry/registries/acrimprbacsrc1ext0m \
  --source hello-world:latest \
  --image step2/hello-world:latest
```

失敗し、権限エラーが出るはず（メッセージを記録）。

ロールを戻す（管理者のターミナル）:

```bash
cd ~/ghq/github.com/miumosh/azure-sandbox-2/acr/cross_subscription_import_rbac/terraform
terraform apply
```
