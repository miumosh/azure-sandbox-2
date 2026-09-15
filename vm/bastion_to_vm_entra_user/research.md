# Azure Bastion + Ubuntu VM を Entra ID ユーザでログインする構成 — 調査結果

調査日: 2026-08-24
対象: Azure Bastion 経由で Linux (Ubuntu) VM に SSH し、**Entra ID のユーザ資格情報**で OS ログインする構成

---

## 1. 結論サマリ

| 問い | 回答 |
| --- | --- |
| Bastion + Ubuntu VM で Entra ID ログインは可能か | **可能。GA 済み。** Bastion ポータル接続 (SSH + Entra ID) は GA、ネイティブクライアント (`az network bastion ssh --auth-type AAD`) も GA |
| 仕組み | VM 拡張 `AADSSHLoginForLinux` + Entra ID が発行する **OpenSSH 証明書**（短命）+ Azure RBAC による認可 |
| VM は Entra 参加 (Entra joined) するのか | **しない。** Linux VM は Entra join されない。Windows VM とは認証フローが根本的に異なる（← ゲストユーザの可否の差の原因） |
| 必要な RBAC | `Virtual Machine Administrator Login` または `Virtual Machine User Login`（+ Bastion 利用時は各リソースへの `Reader`）。**Owner / Contributor では OS ログインできない** |
| 最小 Bastion SKU | ポータル接続なら **Basic** 以上／ネイティブクライアント (`az network bastion ssh`) なら **Standard** 以上。**Developer SKU は不可**（ネイティブクライアント非対応、ポータル接続も要検証扱い） |
| 外部招待ユーザ (B2B ゲスト) | **Windows VM は明確に非サポート。Linux VM は「動く」とされるが公式ドキュメントに明記がなくグレー** → 本構成では**実機検証が必須**。詳細は §6 |

---

## 2. 構成の全体像

```
   [利用者の端末]
        │  ① az login / ポータルサインイン（MFA・条件付きアクセス評価）
        ▼
   [Microsoft Entra ID]  ──② 短命の OpenSSH ユーザ証明書を発行
        │                    (CA = Entra ID、証明書の principal = ユーザ UPN)
        │  ③ RBAC 認可 (pas.windows.net)
        ▼
   [Azure Bastion]  ──④ SSH ブローカ（443 → 22）
        │                Basic 以上 = ポータル / Standard 以上 = ネイティブクライアント
        ▼
   [Ubuntu VM (Private IP のみ)]
        - System-assigned Managed Identity（必須）
        - VM 拡張 AADSSHLoginForLinux
          → sshd の AuthorizedKeysCommand = /usr/sbin/aad_certhandler
          → NSS/PAM が Entra ユーザをローカルユーザとして解決、初回ログインで home 作成
        - アウトバウンド 443 が必要（§4.2）
```

ポイント: **SSH 秘密鍵の配布・管理が一切不要**。ユーザ棚卸しは Entra ID 側のユーザ無効化 / RBAC 剥奪で完結する。

---

## 3. 接続方式の比較

| 方式 | コマンド / 操作 | 最小 Bastion SKU | Entra ID 認証 | 備考 |
| --- | --- | --- | --- | --- |
| A. Bastion ポータル (ブラウザ SSH) | ポータル → VM → 接続 → Bastion → 認証タイプ「Microsoft Entra ID」 | **Basic** | GA | 端末に CLI 不要。最も簡単。条件付きアクセスのデバイス準拠は評価されにくい |
| B. Bastion ネイティブクライアント | `az network bastion ssh --auth-type AAD` | **Standard** | GA | Bastion 側で「ネイティブクライアントサポート」を有効化する必要あり。ファイル転送・カスタムポート可 |
| C. Bastion 経由せず直接 | `az ssh vm -n <vm> -g <rg>` | — | GA | VM の Private IP に到達できる経路（VPN/ER/Peering）が別途必要。Bastion トンネル併用も可 |
| D. 証明書エクスポート + 任意の SSH クライアント | `az ssh config --file ~/.ssh/config ...` | — | GA | OpenSSH 証明書対応クライアント（PuTTY 系も現在は対応）で利用可能 |

> 注: ポータル接続 (A) は「パスワードレス」で、ローカル VM パスワードは不要。ネイティブクライアントの **RDP** はパスワード入力を求められるが、SSH (B) は証明書のみ。

---

## 4. 前提条件・要件

### 4.1 VM 側
- **サポート OS**: Ubuntu 16.04 〜 **24.04**（他に Debian 9-12 / RHEL 7.4-9 / Alma 8,9 / Rocky 8,9 / SLES / openSUSE / Oracle Linux 8,9 / Azure Linux 2.0,3.0）
- **System-assigned Managed Identity が必須**（未設定だと拡張インストールが exit code 22 で失敗）
- **VM 拡張 `Microsoft.Azure.ActiveDirectory / AADSSHLoginForLinux`**（内部で `aadsshlogin`, `aadsshlogin-selinux` パッケージを導入）
- 既存 VM に後から入れる場合、**メモリ 1GB 以上**必須（それ未満はインストール失敗）
- VM Agent (walinuxagent) が稼働していること
- 旧 `AADLoginForLinux` 拡張（デバイスコードフロー版）が入っていると exit code 23 で失敗 → 先に削除

### 4.2 ネットワーク（VM からのアウトバウンド TCP/443）— **クローズド環境で最も詰まりやすい点**

Azure Global の場合、以下への到達が必要:

| エンドポイント | 用途 |
| --- | --- |
| `https://packages.microsoft.com` | パッケージのインストール／更新 |
| `http://169.254.169.254` | Azure Instance Metadata Service (IMDS) |
| `https://login.microsoftonline.com` | PAM 認証フロー |
| `https://pas.windows.net` | **Azure RBAC 認可フロー** |

- Bastion があっても **これらのアウトバウンドは VM 自身に必要**。NSG/Azure Firewall/UDR で全部塞ぐと「接続はできるが認証で切断される」状態になる。
- Private Endpoint 化はできない（上記は Entra/PAS のグローバルエンドポイント）。Firewall なら FQDN 許可、NSG なら Service Tag `AzureActiveDirectory`, `AzureResourceManager` 等での許可を検討。
- HTTP プロキシ環境では `/lib/systemd/system/walinuxagent.service` に `http_proxy` / `https_proxy` / `no_proxy=169.254.169.254` を追記して agent 再起動が必要。

### 4.3 クライアント側
- Azure CLI **2.22.1 以上**（Bastion ネイティブクライアントは **2.32 以上**）
- `az extension add --name ssh`（SSH 拡張、最低 0.1.4）
- OpenSSH 証明書に対応した SSH クライアント（Windows 10 1803+ 同梱の OpenSSH、Cloud Shell 等）
- ポータル接続 (方式 A) の場合はブラウザのみで可

### 4.4 リージョン / クラウド
- Azure Global / Azure Government / 21Vianet で利用可。Japan East / Japan West を含む通常リージョンは対象。
- Bastion Developer SKU は日本リージョン (Japan East / Japan West) にも提供されているが、**ネイティブクライアント非対応・同時 1VM のみ**なので本用途では Basic 以上を推奨。

---

## 5. 認可（RBAC）と OS 上の権限

### 5.1 必要なロール

| ロール | 効果 |
| --- | --- |
| `Virtual Machine Administrator Login` | SSH ログイン可 + **`sudo` が追加認証なしで使える** |
| `Virtual Machine User Login` | SSH ログイン可、**`sudo` は使えない** |

さらに **Bastion 経由**の場合は以下の `Reader` も必要:
- 対象 VM
- VM の NIC（プライベート IP を持つもの）
- Azure Bastion リソース
- （Bastion がピアリング先 VNet にある場合）対象 VM の VNet

### 5.2 重要な制約
- **Owner / Contributor を持っていても OS ログイン権限は付かない**（「VM を管理する人」と「VM に入る人」を意図的に分離、監査可能にする設計）
- ロール割り当てには `Virtual Machine Data Access Administrator` もしくは `Microsoft.Authorization/roleAssignments/write` を含むロールが必要
- 両ロールは `dataActions` を使うため、**個々の VM ではなく管理グループ／サブスクリプション／リソースグループ単位での割り当てが推奨**（サブスクリプションあたりのロール割り当て上限回避）
- Entra のドメインとサインイン名のドメインが一致しない場合、`--assignee` ではなく **`--assignee-object-id` でオブジェクト ID を指定**する必要がある（ゲストユーザで特に該当）

### 5.3 OS 側の挙動（実機で要確認の項目）
- Entra ユーザは NSS/PAM 経由で解決され、**ローカルの `/etc/passwd` には事前登録されない**。初回ログイン時にホームディレクトリが自動作成される。
- ログイン後の Linux ユーザ名 / ホームディレクトリのパス形式（UPN そのままか、記号がサニタイズされるか）は環境差があるため、**検証時に `whoami` と `echo $HOME` で確認すること**（特にゲストユーザの `#EXT#` を含む UPN では要注意 → §6）。
- `sudo` 可否は RBAC ロールにより制御される。個別に `usermod -aG sudo` するような運用は想定外。

---

## 6. 外部招待ユーザ（B2B ゲスト）の制限 — **本調査の核心**

### 6.1 Windows VM: 明確に **非サポート**

Microsoft 公式ドキュメント（Windows VM の Entra サインイン）の "Authentication requirements" に明記:

> **User account type**: Only standard Microsoft Entra user accounts from the same tenant as the azure windows virtual machine are supported. **Guest accounts (B2B users) cannot be used for authentication.**

理由: Windows VM は拡張導入時に **Entra joined デバイス**になり、Entra joined デバイスへのゲスト／外部アカウントでのサインインは仕組み上不可能。UPN が `user_contoso.com#EXT#@tenant.onmicrosoft.com` 形式でテナントドメインと一致しないことも要因。

### 6.2 Linux VM: 公式ドキュメントに**明記なし**。「動く」との情報はあるがグレー

- Linux 版の公式ドキュメントには、ゲスト／外部アカウントを禁じる記述が**存在しない**（Windows 版にはある）。
- Microsoft Q&A の回答では、Linux VM は Entra join されず別フローのため、**外部／ゲストユーザもサインイン可能**とされている。具体的には「外部／ゲストユーザは VM 上の `/etc/aadpasswd` に登録され、そこからサインインが処理される」という説明がなされている。
- ただしこれは **Q&A（サポート回答）レベルの情報であり、公式ドキュメントによる保証ではない**。SLA・サポート面で依拠するのはリスクがある。

**→ 結論: 「Linux ならゲストでも入れる可能性が高いが、必ず実機で検証し、本番採用するならサポートに正式確認を取る」**

### 6.3 ゲストユーザで追加で詰まりうるポイント

| 項目 | 内容 |
| --- | --- |
| UPN 形式 | ゲストの UPN は `user_extdomain.com#EXT#@tenant.onmicrosoft.com`。`#` を含むため、Linux ユーザ名／ホームディレクトリ名として扱われる際に不具合が出ないか要確認 |
| RBAC 割り当て | ゲストにも `Virtual Machine User/Administrator Login` は割り当て可能。ただしドメイン不一致のため **`--assignee-object-id` 指定が必要**になるケースが多い |
| ポータル操作 | ゲストはポータルで**ディレクトリ（テナント）の切り替え**が必要。切り替えないと対象サブスクリプション／Bastion が見えない |
| MFA / 条件付きアクセス | リソーステナント側の CA ポリシーがゲストにも適用される。ゲストのホームテナントの MFA を信頼するには **クロステナントアクセス設定でのトラスト設定**が必要。未設定だとゲストはリソーステナント側で MFA 再登録を求められる |
| ゲスト招待の制限 | テナントの外部コラボレーション設定でゲスト招待自体が禁止されていないか、ゲストの権限が「制限付き」になっていないか |
| ライセンス | 条件付きアクセスは Entra ID P1 以上。ゲストは MAU 課金モデル（月間アクティブユーザ 50,000 まで無料枠） |

### 6.4 ゲストを使わない代替案

| 代替案 | 内容 | トレードオフ |
| --- | --- | --- |
| A. ゲストをメンバーに変換 | Entra ID > ユーザ > 「内部ユーザーに変換」。UPN から `#EXT#` が消えれば Windows/Linux 双方で確実に動作 | 相手組織のアカウントではなく自テナントのアカウントになる。ライセンス／棚卸しの対象になる |
| B. 自テナントに専用アカウントを発行 | 委託先用に `contractor01@yourtenant.onmicrosoft.com` を作成 | 管理対象アカウントが増える。パスワード/MFA 運用が必要 |
| C. ローカルユーザ + Bastion | Entra ID 認証を使わず、従来の SSH 鍵／パスワードで Bastion 接続。鍵は Key Vault から参照可 | Entra ID による集中管理・CA・棚卸しの利点を失う |
| D. Bastion の共有可能リンク (Shareable Link) | Azure アカウントを持たない相手にも URL でアクセス提供（Standard SKU 以上） | 認証が URL 保持のみに依存。Entra ID の MFA/CA が効かない。セキュリティ的に本番非推奨 |

---

## 7. 制約・注意事項の一覧

### 7.1 Bastion 側

- **SKU**: ポータル接続 = Basic 以上、ネイティブクライアント = Standard 以上。**Developer SKU は本用途に不適**（ネイティブクライアント非対応、同時 1VM のみ、VNet ピアリング非対応）
- **IP ベース接続 (IP-Connect) では Entra ID 認証が使えない**（RDP は完全に不可。SSH はネイティブクライアント経由でのみサポート）
- **セッション記録 (Premium SKU) と、ポータルでの RDP + Entra ID 認証は併用不可**（SSH については記載なし → 使うなら要確認）
- ポータル接続で Entra ID 認証の選択肢が出てこない場合、**拡張未インストールか RBAC 未割り当て**が原因（要件を満たさないと選択肢自体が非表示になる）
- ネイティブクライアント接続には Bastion 側の「ネイティブクライアントサポート」有効化が必要
- Bastion は VM と同一 VNet またはピアリング済み VNet に配置。AzureBastionSubnet は **/26 以上**

### 7.2 Entra ID ログイン側

- **条件付きアクセス**: 適用対象アプリは **`Azure Linux VM Sign-In`**（Windows は `Microsoft Azure Windows Virtual Machine Sign-in`）。テナントにこのエンタープライズアプリが存在しないと CA で選択できない
- **デバイス準拠 / Entra ハイブリッド参加を要求する CA は、Windows・macOS 上の Azure CLI でのみ有効**。**Linux 上の Azure CLI と Cloud Shell では非対応**（MFA 要求は Linux/Cloud Shell でも機能する）
- `sshd_config` に `AllowGroups` / `DenyGroups` があると **Entra ユーザの初回ログインが失敗する**（2 回目以降は成功する）。除去するか `match user` ブロック内へ移動する
- **AKS クラスタのノードに対する `az ssh` 拡張の利用は非サポート**
- VMSS は対応するが、`--resource-group` / `--name` で IP 自動解決ができず `az ssh vm --ip` が必要。インスタンスモデルが古いと接続失敗する
- RHEL 7.x / Oracle Linux 7.x は OpenSSH 7.4 が古く、クライアント側 OpenSSH 8.8+ と非互換 → `PubkeyAcceptedKeyTypes=+ssh-rsa-cert-v01@openssh.com` の指定が必要（Ubuntu では該当しない）
- SUSE 15.6 で破壊的変更あり（Ubuntu では該当しない）
- 旧レガシー MFA（ユーザ単位 MFA の Enabled/Enforced）は VM ログインで問題を起こす → CA ベースの MFA に統一する

### 7.3 運用面

- Entra ユーザのログイン可否は **RBAC ロール割り当てのみ**で決まる。ローカルの `sudoers` を直接いじる運用は非推奨（Windows 版では `net localgroup administrators /add` は明確に非サポート）
- Azure Policy で「Entra ログインが有効な Linux VM か」の監査・自動修復、および「未承認のローカルアカウントの検出」が可能
- 監査ログは Entra サインインログ（`Azure Linux VM Sign-In` アプリ）+ Bastion の診断ログ + VM 側 `/var/log/azure/Microsoft.Azure.ActiveDirectory.AADSSHLoginForLinux/CommandExecution.log`

---

## 8. 検証手順（最小構成）

```bash
LOCATION=japaneast
RG=rg-bastion-entra-test
VNET=vnet-test
VM=vm-ubuntu-entra

# 1. RG / VNet / サブネット
az group create -n $RG -l $LOCATION
az network vnet create -g $RG -n $VNET \
  --address-prefix 10.0.0.0/16 \
  --subnet-name snet-vm --subnet-prefix 10.0.1.0/24

# Bastion 用サブネット（名前固定 / /26 以上）
az network vnet subnet create -g $RG --vnet-name $VNET \
  -n AzureBastionSubnet --address-prefix 10.0.0.0/26

# 2. Bastion（ネイティブクライアントも試すなら Standard）
az network public-ip create -g $RG -n pip-bastion --sku Standard --location $LOCATION
az network bastion create -g $RG -n bastion-test \
  --public-ip-address pip-bastion --vnet-name $VNET --location $LOCATION \
  --sku Standard --enable-tunneling true

# 3. Ubuntu VM（パブリック IP なし / システム割り当てマネージド ID 有効）
az vm create -g $RG -n $VM \
  --image Ubuntu2404 \
  --vnet-name $VNET --subnet snet-vm \
  --public-ip-address "" \
  --assign-identity \
  --admin-username azureuser --generate-ssh-keys

# 4. Entra ログイン拡張
az vm extension set \
  --publisher Microsoft.Azure.ActiveDirectory \
  --name AADSSHLoginForLinux \
  -g $RG --vm-name $VM

# 5. RBAC（自分自身に付与する例）
OID=$(az ad signed-in-user show --query id -o tsv)
SCOPE=$(az group show -g $RG --query id -o tsv)
az role assignment create --role "Virtual Machine Administrator Login" \
  --assignee-object-id $OID --assignee-principal-type User --scope $SCOPE
az role assignment create --role "Reader" \
  --assignee-object-id $OID --assignee-principal-type User --scope $SCOPE

# 6a. ネイティブクライアントで接続（Standard 以上）
az extension add --name ssh
VMID=$(az vm show -g $RG -n $VM --query id -o tsv)
az network bastion ssh -n bastion-test -g $RG \
  --target-resource-id "$VMID" --auth-type AAD

# 6b. もしくはポータル: VM → 接続 → Bastion → 認証タイプ「Microsoft Entra ID」
```

### 検証時に確認すべきチェックリスト
- [ ] ポータル接続で「Microsoft Entra ID」が認証タイプに**表示されるか**（表示されない = 拡張 or RBAC 不足）
- [ ] ログイン後の `whoami` / `echo $HOME` / `id` の出力（ユーザ名・ホームパスの形式）
- [ ] `Virtual Machine User Login` のみのユーザで `sudo` が拒否されるか
- [ ] `Virtual Machine Administrator Login` のユーザで `sudo` がパスワードなしで通るか
- [ ] Entra ユーザを無効化 / ロール剥奪した直後に、既存セッションと新規ログインがどう振る舞うか
- [ ] **ゲストユーザ（B2B 招待）で `az login --tenant <resource-tenant>` → Bastion 接続が成功するか**（成功時は `whoami` の出力形式も記録）
- [ ] ゲストユーザに対する条件付きアクセス／MFA の挙動（クロステナント MFA トラストの有無で比較）
- [ ] NSG でアウトバウンドを絞った状態（§4.2 の 4 エンドポイントのみ許可）で認証が通るか
- [ ] `cat /var/log/azure/Microsoft.Azure.ActiveDirectory.AADSSHLoginForLinux/CommandExecution.log` で拡張の状態確認

---

## 9. 未確定事項（要実機検証 / サポート確認）

1. **B2B ゲストユーザによる Linux VM への Entra ID ログインの可否**
   公式ドキュメントに肯定・否定いずれの記述もない。Q&A では「可能」とされるが、本番採用には正式確認を推奨。
2. Bastion **Premium SKU のセッション記録**と SSH + Entra ID 認証の併用可否
   公式には「RDP + Entra ID とセッション記録は併用不可」とのみ記載。SSH については未記載。
3. ゲストユーザ UPN (`#EXT#` を含む) が Linux のユーザ名／ホームディレクトリ名としてどう扱われるか
4. Bastion **Developer SKU** でのポータル接続 + Entra ID 認証の可否（ドキュメント上は「Basic 以上」とされ、Developer は対象外と読める）
5. Entra ユーザの無効化／ロール剥奪が**既存 SSH セッション**に反映されるまでのタイムラグ（証明書の有効期限に依存）

---

## 10. 参考リンク

- [Sign in to a Linux virtual machine in Azure by using Microsoft Entra ID and OpenSSH](https://learn.microsoft.com/en-us/entra/identity/devices/howto-vm-sign-in-azure-ad-linux) — Linux VM の Entra ログイン公式ドキュメント（対応ディストリ、ネットワーク要件、CA、トラブルシュート）
- [Configure Microsoft Entra ID authentication - Azure Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-entra-id-authentication) — Bastion 側の Entra ID 認証設定、必要 SKU / ロール / 制限事項
- [Sign in to a Windows virtual machine in Azure by using Microsoft Entra ID](https://learn.microsoft.com/en-us/entra/identity/devices/howto-vm-sign-in-azure-ad-windows) — **ゲストアカウント非サポートの明記あり**（Windows）
- [Choose the right Azure Bastion SKU](https://learn.microsoft.com/en-us/azure/bastion/bastion-sku-comparison) — SKU 別機能比較表
- [Configure Bastion for native client connections](https://learn.microsoft.com/en-us/azure/bastion/native-client) — ネイティブクライアント有効化
- [Connect to a VM using Bastion - Linux native client](https://learn.microsoft.com/en-us/azure/bastion/connect-vm-native-client-linux)
- [Q&A: Login to VM via bastion with an entra external account](https://learn.microsoft.com/en-us/answers/questions/5496690/login-to-vm-via-bastion-with-an-entra-external-acc) — Windows 不可 / Linux は可能とする回答
- [Q&A: How to have guest user (B2B invited) have access to Virtual Machine](https://learn.microsoft.com/en-us/answers/questions/5569518/how-to-have-guest-user-(b2b-invited)-have-access-t) — メンバー変換のワークアラウンド
- [Q&A: External Entra ID Guest Users Cannot Log In to Entra-Joined VM via AADLoginForWindows](https://learn.microsoft.com/en-us/answers/questions/5780343/external-entra-id-guest-users-cannot-log-in-to-ent)
- [B2B guest user properties - Microsoft Entra External ID](https://learn.microsoft.com/en-us/entra/external-id/user-properties)
