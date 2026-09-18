# ============================================================================
# ルート 入力変数
# - 設定値は原則 locals.tf に置き、機微情報 / 環境依存値 / 検証スイッチのみここ。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID"
  type        = string
}

variable "key_vault_network_mode" {
  description = <<-EOT
    本検証の主スイッチ。Key Vault の公開方式を 3 モードで切り替える。

      "public"     : public 有効 + networkAcls.default_action = Allow。
                     閉域化前のベースライン。AI Foundry も運用端末も自由に到達できる。

      "restricted" : public 有効 + default_action = Deny + bypass = AzureServices
                     + allowed_client_ips のみ許可 (+ PE あり)。
                     「信頼された Azure サービス」の bypass が AI Foundry に効くかを見るモード。

      "private"    : public 無効 (publicNetworkAccess = Disabled) + PE のみ。
                     Key Vault では public 無効にすると networkAcls (ip_rules / bypass)
                     が一切評価されない。AzureServices bypass も効かない点が要注意。

    いずれのモードでも Private Endpoint は作成したままにし、
    「PE を作れば到達性が担保される相手なのか」を切り分けられるようにしている。
  EOT
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "restricted", "private"], var.key_vault_network_mode)
    error_message = "key_vault_network_mode は public / restricted / private のいずれかを指定してください。"
  }
}

variable "allowed_client_ips" {
  description = <<-EOT
    Key Vault の networkAcls.ip_rules に載せる運用端末のグローバル IP。
    裸 IP または CIDR (/31, /32 は裸 IP で指定すること)。

    "restricted" のときに許可 IP として機能する。
    "public" では default_action = Allow のため実質意味を持たない。
    "private" では public 自体が無効なので評価されない (設定値は保持される)。

    現在の IP は curl -s https://ifconfig.me/ip などで確認する。回線により変動する点に注意。
  EOT
  type        = list(string)
  default     = []
}

variable "ai_foundry_public_network_access" {
  description = <<-EOT
    AI Foundry Hub のパブリックアクセス。本検証の前提は「インバウンドのみ閉域化」
    なので既定は "Disabled" (+ amlworkspace の PE を作成)。

    ポータル (ai.azure.com) からの手動確認も行いたい場合のみ一時的に "Enabled" にする。
    ※ Hub 側の公開状態は Key Vault への到達性 (RP -> KV) とは別軸であり、
       本検証の結論には影響しない (検証結果は README.md 参照)。
  EOT
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Enabled", "Disabled"], var.ai_foundry_public_network_access)
    error_message = "ai_foundry_public_network_access は Enabled / Disabled のいずれかを指定してください。"
  }
}

variable "grant_operator_key_vault_role" {
  description = <<-EOT
    terraform 実行者 (現在の Azure CLI ログインユーザー) に Key Vault Administrator を
    付与するか。検証で Key Vault のシークレット一覧を直接確認するために使う。
  EOT
  type        = bool
  default     = true
}

variable "key_vault_trusted_azure_services_bypass" {
  description = <<-EOT
    Key Vault の networkAcls.bypass に "AzureServices"
    (信頼された Azure サービスによるファイアウォール迂回) を設定するか。
    false にすると bypass = "None" になる。

    AI Foundry (Hub) の実体は Azure ML ワークスペースであり、
    "Azure Machine Learning" は Key Vault の信頼されたサービス一覧に載っている。
    このスイッチを false にすることで、閉域化後も接続が解決できるのは
    「PE のおかげ」なのか「trusted services bypass のおかげ」なのかを切り分ける。
  EOT
  type        = bool
  default     = true
}
