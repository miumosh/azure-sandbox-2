# Key Vault 閉域化が AI Foundry の Storage SAS 接続に与える影響

## 1. 調査の目的と前提

AI Foundry (Hub ベース) の Storage 接続を **SAS 認証**で作ると、SAS トークンの実体は
**Hub に紐付く Key Vault のシークレット**として保存される。
この Key Vault を閉域化したときに、その接続が壊れるのかを実機で確認する。

前提 (調査依頼時の指定):

| 項目 | 状態 |
|------|------|
| AI Foundry のインバウンド | **閉域化する** (`publicNetworkAccess = Disabled` + `amlworkspace` の Private Endpoint) |
| AI Foundry のアウトバウンド | **閉域化しない** (managed VNet / VNet 統合を使わない) |
| Key Vault | 本調査で公開方式を切り替える対象 |
| Storage | public のまま固定 (交絡要因を作らないため) |

> **スコープ**: ここで扱うのは Hub ベース (classic) の AI Foundry
> = `Microsoft.MachineLearningServices/workspaces` (`azurerm_ai_foundry`) である。
> 新しい Foundry (Cognitive Services アカウント + プロジェクト) は接続シークレットの
> 保存先が異なるため、本結果をそのまま適用しないこと。

## 2. 結論 (先に要点)

1. **効いているのは Private Endpoint ではなく `networkAcls.bypass = AzureServices` である。**
   AI Foundry (Azure ML) の RP は **Microsoft 管理ネットワーク側のパブリック IP** から
   Key Vault のデータ面を叩く。顧客 VNet は通らないので、Key Vault に Private Endpoint を
   生やしても AI Foundry の経路は 1 ミリも救われない。

2. **`publicNetworkAccess = Disabled` にしても、`bypass = AzureServices` が残っていれば
   SAS 接続は壊れない** (実測)。Key Vault の trusted services バイパスは public 無効時も
   有効なままで、Azure Machine Learning はその一覧に載っている。

3. **`bypass = None` にした瞬間に壊れる。** public 有効 (Deny + 許可 IP) でも、
   public 無効 (PE のみ) でも同じく壊れる。壊れ方は
   「接続のシークレット解決 (listsecrets) が 403」「SAS 接続の新規作成/更新が失敗」。

4. **被害範囲は自分で作った SAS 接続だけではない。** Hub が自動作成する既定データストア
   (`workspaceblobstore` / `workspaceartifactstore` = **Sas**、`workspaceworkingdirectory`
   = **AccountKey**) も同じ Key Vault にシークレットを置いているため、まとめて解決不能になる。

5. **運用者から Key Vault への到達性は別途手当てが要る。** `private` では運用端末からの
   `az keyvault secret list` が 403 になる (許可 IP は public 無効時に評価されない)。

6. **エラー文言が誤解を招く。** 実際にはファイアウォール遮断なのに
   `customer doesn't have required get permission on keyvault.` や
   `the system assigned managed identity of the workspace does not have access to the key vault`
   といった RBAC 風のメッセージが返る。生の Key Vault エラーまで掘ると
   `ForbiddenByFirewall` が見える。

### 2.1 結果サマリ (早見表)

詳細な項目別結果は次章「3. 検証結果マトリクス」の表を参照。
ここでは「結局どのパターンで何が壊れるか」だけを見たい人向けに、条件ごとの
可否をまとめる。

| 条件 | Key Vault publicNetworkAccess | bypass | SAS 接続の解決/新規作成 | Hub 既定データストア | AAD 接続 | 運用端末 → KV |
|------|-------------------------------|--------|--------------------------|------------------------|----------|----------------|
| A: public (ベースライン) | Enabled | AzureServices | OK | OK | OK | OK |
| B: restricted (Deny + 許可IP) | Enabled | AzureServices | OK | OK | OK | OK |
| C: restricted, bypass なし | Enabled | **None** | **NG** | **NG** | OK | OK |
| D: private (PE のみ) | **Disabled** | AzureServices | OK | OK | OK | **NG** |
| E: private, bypass なし | **Disabled** | **None** | **NG** | **NG** | OK | **NG** |

読み方: **AI Foundry 側 (SAS 接続 / 既定データストア) の生死を分けるのは bypass の有無だけ**
(B↔C、D↔E)。`publicNetworkAccess` の Enabled/Disabled (A・B↔D) は AI Foundry 側の結果を
分けない。一方で運用端末からの直接アクセス (T5) は `publicNetworkAccess` で決まる。

## 3. 検証結果マトリクス

`scripts/run_matrix.sh` で 5 組み合わせを順に apply し、**Key Vault のネットワーク設定が
データ面へ伝播するのを 300 秒待ってから**測定した結果 (2026-09-16 / japaneast)。

検証した条件:

| # | `key_vault_network_mode` | publicNetworkAccess | defaultAction | bypass | Key Vault の PE |
|---|--------------------------|---------------------|---------------|--------|------------------|
| A | `public`     | Enabled  | Allow | AzureServices | あり |
| B | `restricted` | Enabled  | Deny  | AzureServices | あり |
| C | `restricted` | Enabled  | Deny  | **None**      | あり |
| D | `private`    | **Disabled** | Deny | AzureServices | あり |
| E | `private`    | **Disabled** | Deny | **None**      | あり |

結果 (OK = 成功 / **NG** = 失敗):

| 検証項目 | 経路 | A | B | C | D | E |
|----------|------|---|---|---|---|---|
| T1 接続の GET (メタデータ) | ARM のみ | OK | OK | OK | OK | OK |
| T2a 接続 `listsecrets` (Hub の SAS) | RP -> KV 読取 | OK | OK | **NG** | OK | **NG** |
| T2b 接続 `listsecrets` (Project の SAS) | RP -> KV 読取 | OK | OK | **NG** | OK | **NG** |
| T3 SAS 接続の新規作成 | RP -> KV 書込 | OK | OK | **NG** | OK | **NG** |
| T8 既定データストア `workspaceblobstore` の資格情報解決 | RP -> KV 読取 | OK | OK | **NG** | OK | **NG** |
| T4 AAD 接続の `listsecrets` (対照群) | KV 非経由 | OK | OK | OK | OK | OK |
| T5 運用端末から `az keyvault secret list` | 端末 -> KV | OK | OK | OK | **NG** | **NG** |
| T6 Hub の `provisioningState` | ARM のみ | OK | OK | OK | OK | OK |
| T7 Project の新規作成 | プロビジョニング | OK | OK | OK | OK | OK |

この表の読み方:

- **縦に見ると**: AI Foundry 側 (T2 / T3 / T8) が壊れるのは **C と E**、すなわち
  `bypass = None` の 2 パターンだけ。`publicNetworkAccess` が Enabled か Disabled かは
  AI Foundry の可否を分けていない (B と D はどちらも全 OK)。
- **B と C の差は `bypass` だけ** (どちらも Deny + 許可 IP + PE あり)。
  ここで結果が割れるので、効いているのが `bypass` だと特定できる。
- **D と E の差も `bypass` だけ** (どちらも public 無効 + PE あり)。
  PE があっても `bypass = None` なら救えない = **PE は AI Foundry の経路に使われていない**。
- **T5 だけは `publicNetworkAccess` で決まる**。運用端末は trusted service ではないため、
  public を落とした D / E では (許可 IP を入れていても) 到達できない。
- **T7 は全パターンで成功**した。Project の作成自体はシークレット解決を伴わない。
  ただし C / E で作った Project の既定データストアは、作成後に T8 と同じ理由で
  解決できない状態になるはず (そこまでは未測定)。

> **測定上の注意**: `networkAcls` 変更の直後 (45 秒後) に測ると、
> 「T2 は OK なのに T3 は NG」という不整合な結果が再現性をもって観測された。
> 伝播が終わるまでの過渡状態であり、**閉域化直後の確認結果は信用してはいけない**。
> 上表はすべて 300 秒待機後の値。

生ログは `results/` 配下 (`results/matrix-run.log` と `results/<mode>-<timestamp>.md`)。

## 4. なぜそうなるのか (エビデンス)

`bypass = None` のときに `listsecrets` が返した生のエラー (抜粋):

```text
KeyVaultErrorException encountered. {
  "error": {
    "code": "Forbidden",
    "message": "Client address is not authorized and caller was ignored because bypass is set to None
                Client address: 4.216.8.1
                Caller: name=microsoft.machinelearningservices/workspaces;
                        appid=906e3aad-7902-4d4c-9fe9-9f33c191a765;
                        oid=bf8f8071-407b-42af-a42e-5008287ba7a3
                Vault: kv-aifkv-xxxxx;location=japaneast",
    "innererror": { "code": "ForbiddenByFirewall" }
  }
}
Please try the 'Resync Keys' action.
```

読み取れること:

- **Caller は `microsoft.machinelearningservices/workspaces` (appid `906e3aad-...`)**。
  ワークスペースのマネージド ID ではなく、Azure ML の**ファーストパーティ アプリ**が
  シークレットを取りに来ている。
- **Client address は `4.216.8.1`** = japaneast の Azure パブリック IP。
  顧客 VNet (`10.60.0.0/16`) ではない。**つまり Private Endpoint は通らない**。
- **`caller was ignored because bypass is set to None`** =
  本来ならこの Caller は trusted services として通していた、という明示。

`private` + `bypass = None` の場合の運用端末側エラーも同様に、
「PE でもない、trusted service でもない」から落ちていることが分かる:

```text
(Forbidden) Connection is not an approved private link and caller was ignored because
bypass is not set to 'AzureServices' and PublicNetworkAccess is set to 'Disabled'.
```

既定データストアの資格情報解決が落ちたときのメッセージ (RBAC 風だが実体は firewall):

```text
Credential Service error due to user error. This can occur if the system assigned managed
identity of the workspace does not have access to the key vault. Please add workspace
managed identity as Contributor for the key vault associated with the workspace.
KeyVaultErrorException encountered. {"error":{"code":"Forbidden", ...
```

### 経路の整理

```
                          [ AI Foundry ポータル / SDK ]
                                     |  (インバウンド: PE で閉域化済み)
                                     v
  +---------------------------------------------------+
  |  Azure ML RP / Credential Service (Microsoft 管理) |
  +---------------------------------------------------+
        |  (1) 接続メタデータ  |  (2) シークレット解決
        v                      v
    [ ARM DB ]          パブリック IP (例 4.216.8.1) で Key Vault データ面へ
                               |
                               |  ★ ここが今回の分岐点
                               |     - bypass = AzureServices → 通る (public 無効でも通る)
                               |     - bypass = None           → ForbiddenByFirewall
                               v
                        [ Key Vault (kv-aifkv-xxxxx) ]
                               ^
                               |  Private Endpoint (10.60.10.x)
                               |  ※ 顧客 VNet 内のクライアント専用。RP はここを通らない
                        [ 運用端末 / VM / AKS ]
```

アウトバウンド閉域化 (managed VNet / VNet 統合) をしていないことは、この結論に対して
**不利にも有利にも働かない**。managed VNet を有効にすると Hub 側のコンピュート
(compute instance / マネージドエンドポイント等) の egress が顧客側マネージド VNet 経由になるが、
上図 (2) の **RP によるシークレット解決は依然として RP のファーストパーティ経路**であり、
`bypass` の要否は変わらない (本調査の前提外のため未実測。ここは推定)。

## 5. 影響度評価

| 観点 | 影響 | 備考 |
|------|------|------|
| 既存 SAS 接続の利用 | `bypass` を残すなら**影響なし** / 外すと**全面停止** | listsecrets が 403 |
| 既存 SAS 接続のメタデータ参照 | 影響なし | ARM 上の情報のみで Key Vault 非経由 |
| SAS 接続の新規作成 / SAS ローテーション | `bypass` を外すと**不可** | シークレット書き込みが 403 |
| Hub 既定データストア (workspaceblobstore 等) | `bypass` を外すと**解決不能** | Hub 作成時から Sas / AccountKey で作られる |
| Entra ID (AAD) 認証の接続 | **影響なし** | Key Vault にシークレットを置かない |
| Hub / Project リソース自体 | 影響なし | `provisioningState` は Succeeded のまま |
| Project の新規作成 | 影響なし | プロビジョニング自体はシークレット解決を伴わない |
| 運用者 / CI からの Key Vault 操作 | `private` で**不可** | PE 到達性 (Bastion/VPN 等) が別途必要 |

### リスクの出方に注意

- **遅延して顕在化する。** Key Vault の `networkAcls` 変更がデータ面に反映されるまで数分かかる。
  変更直後は「読み取りは通るのに書き込みは落ちる」といった中途半端な状態が観測された
  (本検証でも再現。`scripts/run_matrix.sh` は既定で 300 秒待ってから測定している)。
  閉域化直後に "問題なし" と判断すると危険。
- **Network Security Perimeter (NSP) を被せると `bypass` は無効化される** ため、
  NSP 導入時は `bypass = AzureServices` を残していても同じ破綻が起きる
  ([Key Vault のドキュメント](https://learn.microsoft.com/azure/key-vault/general/overview-vnet-service-endpoints)参照)。

## 6. 推奨対応

1. **閉域化する場合も `networkAcls.bypass = AzureServices` は必ず残す。**
   `publicNetworkAccess = Disabled` + Private Endpoint + `bypass = AzureServices` の組み合わせなら、
   AI Foundry の SAS 接続は維持されたまま、インターネットからの到達だけを落とせる (実測済み)。
   これが「影響を出さずに閉じる」現実解。

2. **`bypass` を外す (完全遮断) 要件がある場合は、SAS / AccountKey 接続を捨てる必要がある。**
   - 接続を Entra ID (AAD) 認証へ移行する。AAD 接続は Key Vault を使わないため無傷 (実測済み)。
   - ただし Hub 既定データストアの資格情報方式 (credential-based / identity-based) は
     **Hub 作成時に決まる**ため、既存 Hub の作り替えが必要になる可能性が高い。
     移行コストは「接続の張り替え」ではなく「Hub 再作成」で見積もること。

3. **Key Vault を閉じる前に、運用者側の到達経路を先に用意する。**
   `private` にすると運用端末からシークレットを確認できなくなる。VNet 内の踏み台 / Bastion / VPN、
   あるいは `restricted` (public 有効 + Deny + 許可 IP) に留める判断を先に決めておく。

4. **切り替え後の確認は数分待ってから行い、RBAC 風のエラーを鵜呑みにしない。**
   `customer doesn't have required get permission on keyvault` と出ても、まず
   `networkAcls` を疑う。復旧後は AI Foundry 側の **"Resync Keys"** を実行する
   (エラーメッセージ自身が案内している)。

## 7. 検証環境の構成

`../ai_foundry` を土台に、Key Vault の公開方式だけを動かせるようにしたもの。

```
ai_foundry_keyvault_relation/
├── providers.tf              azurerm / azapi / random / time
├── variables.tf              subscription_id + 検証スイッチ
├── locals.tf                 リソース名・ネットワーク・Key Vault モードの解決
├── main.tf                   RG / VNet / Private DNS Zone / 各モジュール呼び出し
├── connections.tf            SAS 発行 + AI Foundry の接続 3 本 (azapi)
├── outputs.tf                verify.sh が読む出力
├── terraform.tfvars.sample   テンプレート (commit する)
├── terraform.tfvars          実値 (.gitignore 済み / commit しない)
├── .gitignore                このディレクトリ専用
├── modules/
│   ├── key_vault/            Key Vault + PE (閉域化スイッチ)
│   ├── storage/              Storage + コンテナ + PE
│   └── ai_foundry/           Hub + Project + amlworkspace PE
└── scripts/
    ├── verify.sh             1 モード分の実測
    └── run_matrix.sh         全組み合わせを apply -> 伝播待ち -> 実測
```

`../ai_foundry` からの主な差分:

- Private DNS Zone の作成を各モジュールからルートへ集約した
  (`create_private_dns_zone` フラグのやり取りをやめ、ゾーン ID を配る方式)。
- AI Services (Cognitive Account) は作らない。今回の主題と無関係でコストと交絡要因になるため。
- 代わりに Hub 自身の Private Endpoint (`amlworkspace`) を作り、
  「インバウンドのみ閉域化」という前提を再現する。
- `azapi` で `Microsoft.MachineLearningServices/workspaces/connections` を作る
  (AzureRM が未対応)。SAS は `sensitive_body` に分離して state 上の平文化を避けている。

### 作成される接続

| 接続名 | スコープ | 認証 | Key Vault シークレット |
|--------|----------|------|------------------------|
| `conn-blob-sas-hub` | Hub | SAS | `<workspaceId>-connblobsashub` (contentType `WorkspaceConnectionSecret`) |
| `conn-blob-sas-project` | Project | SAS | `<workspaceId>-connblobsasproject` |
| `conn-blob-aad-project` | Project | AAD | **なし** (対照群) |

Hub 作成時に自動で作られるシークレット (これも巻き込まれる):

| シークレット | contentType | 対応するデータストア |
|--------------|-------------|----------------------|
| `<id>-workspaceblobstore...` | `application/vnd.ms-StorageAccountAccessKey` | `workspaceblobstore` (Sas) |
| `<id>-workspaceartifactstore...` | 同上 | `workspaceartifactstore` (Sas) |
| `<id>-workspaceworkingdirectory...` | 同上 | `workspaceworkingdirectory` (AccountKey) |

## 8. 検証方法 (再現手順)

```bash
cp terraform.tfvars.sample terraform.tfvars
# subscription_id と allowed_client_ips (curl -s https://ifconfig.me/ip) を埋める

terraform init
terraform apply          # ベースライン (key_vault_network_mode = "public")

./scripts/verify.sh --with-provisioning     # 1 モードだけ測る
./scripts/run_matrix.sh                     # 全 5 組み合わせを自動で回す (約 30 分)
```

結果は `results/<mode>-<timestamp>.md` に出る (`results/` は `.gitignore` 済み。
SAS が混入しうるため追跡しない。`verify.sh` 側でも `sv=` / `sig=` / `se=` はマスクしている)。

### 検証している経路

| ID | 内容 | 経路 |
|----|------|------|
| T1 | 接続の GET | ARM のみ。Key Vault 非経由 |
| T2a / T2b | 接続の `listsecrets` (Hub / Project) | **RP -> Key Vault 読み取り** |
| T3 | SAS 接続の新規作成 | **RP -> Key Vault 書き込み** (キャッシュで誤魔化されない経路) |
| T4 | AAD 接続の `listsecrets` | 対照群。Key Vault 非経由 |
| T5 | 運用端末から `az keyvault secret list` | 人間 / CI -> Key Vault データ面 |
| T6 | Hub の `provisioningState` | リソース自体の健全性 |
| T7 | Project の新規作成 | プロビジョニング経路 |
| T8 | `workspaceblobstore` の `listSecrets` | **Hub 既定データストアの資格情報解決** |

## 9. 後片付け

```bash
terraform destroy
```

Key Vault は `purge_soft_delete_on_destroy = true` にしてあるため、
論理削除済みの Vault もパージされる (サンドボックス用途の設定)。

## 10. 参考

- [Virtual network service endpoints for Azure Key Vault](https://learn.microsoft.com/azure/key-vault/general/overview-vnet-service-endpoints)
  — trusted services 一覧 (Azure Machine Learning を含む) と、
  「public 無効でも trusted services のバイパスは効き続ける」「NSP を被せるとバイパスは無効化される」の記述。
- [How to configure network isolation for Microsoft Foundry](https://learn.microsoft.com/azure/ai-foundry/how-to/configure-private-link)
  — インバウンド / アウトバウンドの分離の考え方。

## 11. 補足調査 (未検証・一次情報からの推測): Application Gateway の Key Vault 証明書参照

> **本章はこのサンドボックスで実機検証していない。** AI Foundry の調査 (1〜10 章) と違い、
> Microsoft Learn の一次情報を読んだ上での推測でまとめている。本番適用前に必ず実機確認すること。

### 11.1 質問

> AppGW の証明書を Key Vault から参照している場合、AppGW の UAMI (ユーザー割り当てマネージド ID)
> に権限を付与して取得しているとする。このとき、Key Vault の PE (Private Endpoint) サブネットで
> AppGW からのアクセスを許可 (NSG 等) しておけば、Key Vault を閉域化しても問題ないか？

### 11.2 結論 (推測)

**基本的には問題ない、というのが公式ドキュメント上の結論。** ただし AI Foundry の調査結果と
異なり、AppGW は **AI Foundry (Azure ML) とは経路の性質が根本的に違う** ため、
「PE を許可すれば OK」という発想自体が両者で真逆の結論になる点に注意。

| | AI Foundry (1〜10 章の実測) | Application Gateway (本章・推測) |
|---|---|---|
| 証明書/シークレットを取得する主体 | Azure ML の RP (ファーストパーティ アプリ) | **AppGW インスタンス自身** (顧客のサブネットに NIC を持つ実体) |
| 取得元の送信元アドレス | Microsoft 管理ネットワークのパブリック IP (実測: `4.216.8.1` 等) | **顧客 VNet 内、AppGW 専用サブネットの IP** |
| Key Vault の PE は効くか | **効かない** (RP は顧客 VNet を経由しない) | **効く** (AppGW 自身が VNet 内から呼ぶため) |
| 閉域化時に必要なもの | `networkAcls.bypass = AzureServices` (実測で確認済み) | PE 経由の到達性 (DNS + NSG + ルーティング)、または VNet 規則 + 信頼済みサービス |

> 表中の略語: **ML** = Machine Learning (Azure Machine Learning。AI Foundry Hub の実体である
> ワークスペースを提供しているサービス)。**RP** = Resource Provider (Azure Resource Manager
> 配下でリソースの作成・管理 API を提供する Azure 内部のサービス群。ここでは
> `Microsoft.MachineLearningServices` の RP を指し、接続のシークレット解決などを
> 顧客に代わって実行する Microsoft 管理下のコンポーネントを指している)。

つまり「Key Vault を閉じても AppGW からは届く」という直感は AI Foundry には**成立しないが**、
AppGW には**成立しうる**。両者を同列に考えないこと。

### 11.3 根拠 (一次情報)

[TLS termination with Azure Key Vault certificates](https://learn.microsoft.com/azure/application-gateway/key-vault-certs)
(Microsoft Learn, `application-gateway/key-vault-certs.md`) の "Verify Firewall Permissions to
Key Vault" 節に、閉域化された Key Vault への到達方法として次のように明記されている:

> Steps 1-3 are not required if your Key Vault has a Private Endpoint enabled. The application
> gateway can access the Key Vault using the private IP address.
>
> If using Private Endpoints to access Key Vault, you must link the `privatelink.vaultcore.azure.net`
> private DNS zone, containing the corresponding record to the referenced Key Vault, to the virtual
> network containing Application Gateway. Custom DNS servers may continue to be used on the virtual
> network instead of the Azure DNS provided resolvers, however the private DNS zone needs to remain
> linked to the virtual network as well.

つまり公式手順として **「Key Vault に PE があれば、AppGW はそのプライベート IP 経由で到達できる」**
と明記されており、ネットワークルール (VNet 規則 / サービスエンドポイント) や信頼済みサービスの
バイパスは PE がある場合は**不要**とされている。ユーザーの想定 (PE サブネットで AppGW を許可すれば
良い) は、この記述と整合する。

一方で、同じ Microsoft のトラブルシューティング記事
[Troubleshoot Application Gateway Key Vault certificate errors](https://learn.microsoft.com/troubleshoot/azure/application-gateway/troubleshoot-application-gateway-key-vault-certificate)
には、やや異なるニュアンスの記述もある:

> Application Gateway v2 doesn't appear on the Key Vault trusted services list. Even if
> `bypass: "AzureServices"` is set, the Application Gateway subnet must be explicitly added to the
> Key Vault network rules, **or a private endpoint must be configured**.

> If public network access is completely disabled on the key vault (not only firewalled), a private
> endpoint is required instead of VNet service endpoints... you must create a private endpoint in a
> VNet that's reachable by Application Gateway. Then, you must configure an Azure Private DNS zone
> so that the key vault hostname resolves to the private IP.

両記事を合わせると:

- **trusted services バイパス単体 (VNet 規則なし) は AppGW には効かない** (この点は
  [Key Vault 側の trusted services 一覧](https://learn.microsoft.com/azure/key-vault/general/overview-vnet-service-endpoints)
  に "Azure Application Gateway" が載っていることと矛盾するように見えるが、トラブルシュート記事の
  方が「実際に運用でハマったケース」を扱っているため、**トラブルシュート記事の記述を優先して
  考えるべき**)。
- **PE 経由の到達性、または VNet 規則 (service endpoint) のどちらかがあれば到達できる**。
  ユーザーの想定している「PE サブネットで AppGW を許可」は前者のパターンに該当し、
  公式手順として存在する。

> 参考までに、Web 検索で見つかった非公式情報 (コミュニティ Q&A や個人ブログ) には
> 「AppGW は Key Vault の PE を使えない」という記述も見られた。これは恐らく本機能が
> 拡張される前の古い制限についての言及で、現行の Microsoft Learn (2026-08 更新) とは
> 一致しない。本番判断は必ず現行の一次情報 (上記 2 リンク) で確認すること。

### 11.4 「PE サブネットで許可すれば OK」が成立するための前提条件

ユーザーの想定通りに動くには、少なくとも以下が揃っている必要がある (すべて一次情報からの
推測。実機未検証):

1. **DNS ゾーンのリンク先**: `privatelink.vaultcore.azure.net` の Private DNS Zone が、
   Key Vault の PE を置いた VNet だけでなく **AppGW が属する VNet (ハブ&スポーク構成なら
   AppGW 側のスポーク VNet) にもリンクされていること**。リンクが無いと AppGW からの名前解決が
   パブリック IP に落ち、ファイアウォールに弾かれる。VNet peering していても DNS ゾーンリンクは
   別物なので見落としやすい。
2. **ネットワーク到達性 (今回の質問の核心)**: KV の PE を置いたサブネットの **NSG が
   AppGW のサブネットからの inbound 443 を許可**していること。AppGW と KV の PE が別 VNet の
   場合は VNet peering (と、ピアリング先への経路がルートテーブルで塞がれていないこと) も必要。
3. **UAMI の RBAC**: `Key Vault Secrets User` ロール (RBAC モデルの場合) または
   アクセスポリシーの `Get` 権限 (証明書は Secret として保存されるため `Certificates` ではなく
   `Secrets` の権限)。ここはユーザーの前提通り付与済みとのことなので問題ない。
4. **Key Vault の `publicNetworkAccess`**: `Disabled` にする場合、PE のみで到達可能になる。
   `Enabled` + `Deny` (public のまま絞る) にする場合は、上記 PE 到達性に加えて
   AppGW のサブネットを `networkAcls.virtual_network_subnet_ids` (VNet 規則 /
   `Microsoft.KeyVault` サービスエンドポイント) にも入れておくと、トラブルシュート記事の
   推奨構成 (VNet 規則 + trusted services) によりいっそう安全側に倒せる。
   PE のみに頼る場合は 3 と本項が特に重要。
5. **証明書の自動更新ポーリング (4 時間おき)** も同じ経路を通るため、初回だけでなく
   継続的にこの到達性が保たれている必要がある。ネットワーク変更 (NSG 更新、Vnet peering 変更等)
   の影響を受けやすい経路であることは運用上留意する。

### 11.5 まとめ

> **推測での結論**: 質問にある「Key Vault の PE サブネットで AppGW を許可しておけば良い」は、
> 公式ドキュメント ([key-vault-certs.md](https://learn.microsoft.com/azure/application-gateway/key-vault-certs))
> に明記された正規の構成であり、**AI Foundry のケースと異なり実際に機能する可能性が高い**。
> これは AppGW インスタンス自身が顧客 VNet 内から Key Vault を呼ぶため。
> ただし「PE を置いて NSG で許可するだけ」で完結するのではなく、
> **AppGW 側 VNet への Private DNS Zone リンク**が最も見落としやすい前提条件になる
> (これが無いと PE があっても名前解決がパブリックに逃げて閉域化の影響を受ける)。
> 本サンドボックスでは実機検証していないため、本番適用前に AppGW を含めた実機確認を推奨する。
