# ============================================================================
# cognitive_account モジュール 入力変数
# ============================================================================
variable "name" {
  description = "Cognitive アカウント名 (custom_subdomain_name の既定値にもなる)"
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "kind" {
  description = <<-EOT
    アカウントの種別。この検証で使うのは以下の 3 つ。

      "SpeechServices" : Speech。PE 利用時はカスタムサブドメイン必須で、
                         有効化すると SDK の初期化方法が変わる (取り消し不可)。
      "AIServices"     : Speech / Vision / Language / OpenAI を束ねた統合エンドポイント。
                         それ自体が現行 (v2) の AI Foundry リソースでもある。
      "OpenAI"         : Azure OpenAI 専用。
  EOT
  type        = string
}

variable "sku_name" {
  type    = string
  default = "S0"
}

variable "custom_subdomain_name" {
  description = <<-EOT
    カスタムサブドメイン名 (グローバル一意)。null の場合はアカウント名をそのまま使う。

    Private Endpoint / Entra ID 認証 / network_acls のいずれにも必須。
    ForceNew かつ Azure 側でも取り消せないため、後から足すとアカウント再作成になる。
  EOT
  type        = string
  default     = null
}

variable "public_network_access_enabled" {
  description = <<-EOT
    パブリックエンドポイントそのものを開くか。network_acls より上位のゲートで、
    false にした時点で network_acls.default_action は公開経路の判定に効かなくなる。
  EOT
  type        = bool
  default     = false
}

variable "local_auth_enabled" {
  description = "API キー認証の可否。false にすると Entra ID 認証のみになる"
  type        = bool
  default     = true
}

variable "project_management_enabled" {
  description = <<-EOT
    ARM 上の allowProjectManagement。kind = AIServices では Azure が自動で true にするため
    既定を true にして実態と揃える。false のままだと毎回差分が出て、この属性は ForceNew の
    ためアカウントごと再作成される (エンドポイント / キー / PE が作り直される)。

    その代わり配下に v2 プロジェクトが自動生成され、destroy が 409 で止まる原因になる
    (README §6 に削除手順あり)。
  EOT
  type        = bool
  default     = true
}

variable "network_acls" {
  description = <<-EOT
    network_acls ブロック。null の場合はブロック自体を作らない。
    public_network_access_enabled = true のときのみ意味を持つ
    (PE 経由の経路は影響を受けない)。

    bypass は kind が OpenAI / AIServices / TextAnalytics 以外だと plan 時エラーになるため、
    SpeechServices と共通で回す場合は null にしておくこと。
  EOT
  type = object({
    default_action             = optional(string, "Deny")
    bypass                     = optional(string)
    ip_rules                   = optional(list(string), [])
    virtual_network_subnet_ids = optional(list(string), [])
  })
  default = null
}

# ---- Private Endpoint ------------------------------------------------------
variable "create_private_endpoint" {
  description = <<-EOT
    Private Endpoint を作成するか。
    subnet_id は同一 apply 内で作られる場合 plan 時に未確定になり得るため、
    作成有無は ID の null 判定ではなくこのフラグで制御する。
  EOT
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = "PE を配置するサブネット ID (create_private_endpoint = true のとき必須)"
  type        = string
  default     = null

  validation {
    condition     = !var.create_private_endpoint || var.private_endpoint_subnet_id != null
    error_message = "create_private_endpoint = true の場合は private_endpoint_subnet_id を指定してください。"
  }
}

variable "private_dns_zone_ids" {
  description = <<-EOT
    PE の DNS Zone Group に登録する Private DNS Zone の ID。key はゾーン識別子。

    ★ここがこの構成の要。PE の subresource は "account" の 1 種類しかないが、
    クライアントが引くホスト名 (cognitiveservices / openai / services.ai) ごとに
    ゾーンが必要になる。ホスト名ごとに PE を増やすのではなくゾーンを増やすのが正解。

    ゾーンが足りないと:
      public 無効 -> 名前解決できず到達不能
      public 有効 -> 公開 IP に解決され、黙ってインターネット経由になる (エラーが出ない)
  EOT
  type        = map(string)
  default     = {}
}

# ---- Virtual Network Injection (Foundry v2 の送信側閉域化) -------------------
variable "network_injection" {
  description = <<-EOT
    Foundry v2 の virtual network injection。null ならブロックを作らない。

    Hub (v1) の managed_network が「Microsoft 管理サブスクに Hub 専用 VNet を作る」方式
    なのに対し、こちらは **あなたの VNet のサブネットに Agent のコンテナを注入する**方式。
    トラフィックが自分の VNet 境界に留まる点が根本的に違う。

    subnet_id の要件 (MS Docs):
      - Microsoft.App/environments に委任されていること
      - 最小 /27、**推奨 /24** (Container Apps の要件に由来)
      - RFC1918 (10/8, 172.16/12, 192.168/16) または CGNAT (100.64/10 の一部)
      - **Foundry リソース 1 つにつき専用サブネット 1 つ**。共有不可

    重大な制約: **アカウント作成時にしか設定できない。**
    既存アカウントに後から足すことはできず、再作成が必要。
  EOT
  type = object({
    scenario  = optional(string, "agent")
    subnet_id = string
  })
  default = null
}
