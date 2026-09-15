# ============================================================================
# ルート 入力変数
# - 構成値は原則 locals.tf に置き、機微情報 / 環境依存値 / 検証スイッチのみここに置く。
# - 実際の値は terraform.tfvars (gitignore 済み)。雛形は terraform.tfvars.sample。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "location" {
  description = "全リソースのリージョン"
  type        = string
  default     = "japaneast"
}

# ---- 検証の主役スイッチ -----------------------------------------------------
variable "ai_network_mode" {
  description = <<-EOT
    AI サービス 3 アカウント (Speech / AIServices / OpenAI) の公開方式。
    閉域化の可否を A/B 比較するためのスイッチ。

      "private" (既定) : public_network_access_enabled = false。
                         Private Endpoint 経由のみ。今回の検証本命。
                         AI Foundry ポータル / Speech Studio は VNet 内からのみ、
                         かつ一部機能は VNet 内でも使えない (README §4 参照)。

      "portal"         : public 有効 + networkAcls.default_action = Allow。
                         PE は併存するがインターネットからも到達可能。
                         ポータルが確実に使える唯一のモード (ai/ai_foundry で実測済み)。

      "restricted"     : public 有効 + default_action = Deny + allowed_client_ips のみ許可。
                         API は許可 IP から可。ポータルは使用不可 (ai/ai_foundry で実測済み)。

    いずれのモードでも PE 経由の経路は維持される。
  EOT
  type        = string
  default     = "private"

  validation {
    condition     = contains(["private", "portal", "restricted"], var.ai_network_mode)
    error_message = "ai_network_mode は private / portal / restricted のいずれかを指定してください。"
  }
}

variable "allowed_client_ips" {
  description = <<-EOT
    networkAcls の ip_rules に載せるグローバル IP。裸 IP または CIDR
    (ARM 仕様上 /31・/32 は非対応なので裸 IP で書く)。

    ai_network_mode = "restricted" のときのみ許可 IP として機能する。
    現在の IP は `curl -s https://ifconfig.me/ip` で確認する。
  EOT
  type        = list(string)
  default     = []
}

# ---- AI Foundry Hub (v1) ---------------------------------------------------
variable "enable_foundry_hub" {
  description = <<-EOT
    AI Foundry Hub (v1 / Azure ML workspace) + そのバックエンド Storage / Key Vault を
    作成するか。

    「AI Foundry が利用する Storage Account との紐づけ」「Key Vault に Secret が
    登録される挙動」を検証したい場合のみ true にする。

    false の場合は kind = AIServices アカウント (= v2 の AI Foundry リソース) だけになり、
    Storage / Key Vault はそもそも不要になる (README §5.1 参照)。
  EOT
  type        = bool
  default     = true
}

variable "hub_dependencies_private" {
  description = <<-EOT
    Hub のバックエンド Storage / Key Vault も閉域化するか。
    「Storage の閉域化はしてはいけないのか / 必須なのか」を実証するためのスイッチ。

      true  : Storage / Key Vault とも public 無効 + PE。Hub は managed VNet を有効化し、
              Storage 側は bypass = AzureServices で信頼済みサービス経路を残す。
              なお Hub の「作成」に managed VNet は不要 (A/B テストで実証済み)。
              効くのは prompt flow / 評価などの実行時。docs/07-managed-network.md 参照。
      false : Storage / Key Vault は public のまま (PE は併存)。
              ai/ai_foundry と同じ「ポータル優先」構成。

    true にすると terraform 実行端末から Storage データ面 (コンテナ作成) に到達できない。
    そのため hub_storage_container_names は既定で空にしてある。
  EOT
  type        = bool
  default     = true
}

# ---- 検証用 Jumpbox --------------------------------------------------------
variable "enable_jumpbox" {
  description = <<-EOT
    VNet 内から名前解決 / 疎通を確認するための Linux VM を作成するか。

    閉域化した AI サービスは「VNet の中からしか」検証できない。
    実行端末からの nslookup / curl では何も確認できないため、
    検証するなら実質必須。確認は SSH ではなく `az vm run-command` で行う
    (verify.sh がこれを使う)。
  EOT
  type        = bool
  default     = true
}

variable "enable_bastion" {
  description = <<-EOT
    Azure Bastion + Windows VM を作成するか。**AI Foundry ポータルを
    ブラウザで手動確認する場合のみ** true にする。

    Bastion (Basic SKU) は起動している間つねに課金される (時間課金 + データ転送)。
    DNS / API の疎通確認だけなら enable_jumpbox の Linux VM で足りるので、
    既定は false。手順は README §4.1 を参照。
  EOT
  type        = bool
  default     = false
}

variable "jumpbox_admin_username" {
  description = "検証用 VM の管理者ユーザー名"
  type        = string
  default     = "azureuser"
}

variable "windows_jumpbox_admin_password" {
  description = <<-EOT
    Bastion 経由でログインする Windows VM のパスワード (enable_bastion = true のとき必須)。
    12 文字以上・大小英数記号のうち 3 種類以上。tfvars に平文で置くことになるため、
    検証が終わったら VM ごと destroy すること。
  EOT
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.windows_jumpbox_admin_password == null || length(coalesce(var.windows_jumpbox_admin_password, "")) >= 12
    error_message = "windows_jumpbox_admin_password は 12 文字以上を指定してください。"
  }
}

# ---- Foundry v2 virtual network injection ----------------------------------
variable "enable_vnet_injection" {
  description = <<-EOT
    Foundry v2 の virtual network injection を検証するための専用アカウントを作るか。

    Hub (v1) の managed_network が「Microsoft 管理サブスクに Hub 専用 VNet を作る」方式
    なのに対し、こちらは **あなたの VNet のサブネットに Agent のコンテナを注入する**方式。

    network_injection は **アカウント作成時にしか設定できない**ため、既存の
    ais-* アカウントに後付けできず、専用アカウント (aisinj-*) を別に立てる。
    snet-agent (Microsoft.App/environments 委任) も併せて使う。

    詳細は docs/08-v1-vs-v2.md。
  EOT
  type        = bool
  default     = true
}

# ---- モデルデプロイ --------------------------------------------------------
variable "enable_model_deployment" {
  description = <<-EOT
    OpenAI アカウントに gpt-4o-mini をデプロイするか。
    モデルデプロイは ARM コントロールプレーン操作なので、public 無効でも
    terraform から作成できる (データ面と経路が違う点がこの検証の要点のひとつ)。

    デプロイが無いと「閉域経路で実際に推論できたか」を確認できないため既定は true。
    クォータ不足で apply が落ちる場合は false にする (README §6 のトラブルシュート参照)。
  EOT
  type        = bool
  default     = true
}
