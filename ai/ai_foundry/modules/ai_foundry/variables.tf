# ============================================================================
# ai_foundry モジュール 入力変数
# ============================================================================
variable "account_name" {
  description = "AI Foundry (Hub) 名。既定では AI Services 名の導出元にもなる"
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

# ---- AI Foundry (Hub) ------------------------------------------------------
variable "storage_account_id" {
  description = "Hub に紐付ける Storage Account の ID (必須)"
  type        = string
}

variable "key_vault_id" {
  description = "Hub に紐付ける Key Vault の ID (必須)"
  type        = string
}

variable "application_insights_id" {
  type    = string
  default = null
}

variable "container_registry_id" {
  type    = string
  default = null
}

variable "friendly_name" {
  type    = string
  default = null
}

variable "description" {
  type    = string
  default = null
}

variable "public_network_access" {
  description = <<-EOT
    Hub 自体のパブリックアクセス ("Enabled" / "Disabled")。
    "Disabled" にする場合、Hub 用の Private Endpoint (サブリソース amlworkspace) を
    別途用意しないと AI Foundry ポータル / SDK から到達できなくなる。
  EOT
  type        = string
  default     = "Enabled"

  validation {
    condition     = contains(["Enabled", "Disabled"], var.public_network_access)
    error_message = "public_network_access は Enabled / Disabled のいずれかを指定してください。"
  }
}

variable "managed_network_isolation_mode" {
  description = "Hub のマネージド VNet 分離モード (None / AllowInternetOutbound / AllowOnlyApprovedOutbound)。null でブロック省略"
  type        = string
  default     = null
}

variable "high_business_impact_enabled" {
  description = "High Business Impact (HBI) ワークスペースとして作成するか。作成後は変更不可"
  type        = bool
  default     = false
}

# ---- AI Foundry Project ----------------------------------------------------
variable "project_name" {
  description = "AI Foundry Project 名。null の場合 aifp-<account_name> を使う"
  type        = string
  default     = null
}

variable "project_friendly_name" {
  type    = string
  default = null
}

variable "project_description" {
  type    = string
  default = null
}

# ---- Cognitive Services (AI Services) --------------------------------------
variable "ai_services_name" {
  description = "AI Services (Cognitive Account) 名。null の場合 ais-<account_name> を使う"
  type        = string
  default     = null
}

variable "ai_services_custom_subdomain_name" {
  description = <<-EOT
    カスタムサブドメイン名 (グローバル一意)。null の場合 AI Services 名をそのまま使う。
    Private Endpoint / Entra ID 認証を使うには必須。
  EOT
  type        = string
  default     = null
}

variable "ai_services_sku_name" {
  type    = string
  default = "S0"
}

variable "ai_services_public_network_access_enabled" {
  type    = bool
  default = false
}

variable "ai_services_local_auth_enabled" {
  description = "API キー認証の可否。false にすると Entra ID 認証のみになる"
  type        = bool
  default     = true
}

variable "ai_services_project_management_enabled" {
  description = <<-EOT
    AI Foundry プロジェクトをこのアカウント配下で管理できるようにするか
    (ARM 上の allowProjectManagement)。

    AI Foundry と紐付けると Azure 側が自動で true にするため、既定を true にして
    実態と揃えている。false のままにすると Terraform が毎回 true -> false に
    戻そうとし、この属性は ForceNew のためアカウントごと再作成される
    (エンドポイント / アクセスキー / PE が作り直される) 点に注意。
  EOT
  type        = bool
  default     = true
}

variable "ai_services_network_acls" {
  description = <<-EOT
    network_acls ブロック。null の場合はブロック自体を作らない。
    public_network_access_enabled = true のときのみ意味を持つ (PE 経由の経路は影響を受けない)。

    bypass に "AzureServices" を指定すると、信頼された Azure サービスからのアクセスを
    許可 IP に関係なく通す。ポータル操作で許可 IP を入れても不足する場合の次の一手。
  EOT
  type = object({
    default_action             = optional(string, "Deny")
    bypass                     = optional(string)
    ip_rules                   = optional(list(string), [])
    virtual_network_subnet_ids = optional(list(string), [])
  })
  default = null
}

# ---- Private Endpoint / Private DNS Zone -----------------------------------
variable "create_private_endpoint" {
  description = <<-EOT
    AI Services の Private Endpoint を作成するか。
    subnet_id は同一 apply 内で作られる場合 plan 時に未確定になり得るため、
    作成有無は ID の null 判定ではなくこのフラグで制御する。
  EOT
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" {
  description = "AI Services の Private Endpoint を配置するサブネット ID (create_private_endpoint = true のとき必須)"
  type        = string
  default     = null

  validation {
    condition     = !var.create_private_endpoint || var.private_endpoint_subnet_id != null
    error_message = "create_private_endpoint = true の場合は private_endpoint_subnet_id を指定してください。"
  }
}

variable "private_endpoint_location" {
  description = "PE の配置リージョン。null の場合 var.location を使う (Hub と別リージョンに AI Services を置く場合に指定)"
  type        = string
  default     = null
}

variable "create_private_dns_zone" {
  description = "Private DNS Zone をこのモジュールで作成するか。false の場合 private_dns_zone_ids を使う"
  type        = bool
  default     = true
}

variable "private_dns_zone_names" {
  description = <<-EOT
    AI Services (kind = AIServices) 向けの Private DNS Zone 名。
    サブリソース "account" の PE は 1 個だが、その NIC のプライベート IP に対して
    クライアントが引くホスト名ごとのゾーンに A レコードを登録する必要がある。

    既定は cognitiveservices のみ (Speech / Vision / Language / Content Safety 用途、
    AOAI は別アカウント / 別モジュールに分離する方針)。
    このアカウントに OpenAI モデルをデプロイし <subdomain>.openai.azure.com で呼ぶ場合は
    "privatelink.openai.azure.com" を、Azure AI Inference SDK で
    <subdomain>.services.ai.azure.com を使う場合は
    "privatelink.services.ai.azure.com" を追加すること。
    ゾーンが足りないと public 無効のため名前解決できず到達不可になる。
  EOT
  type        = list(string)
  default = [
    "privatelink.cognitiveservices.azure.com",
  ]
}

variable "private_dns_zone_ids" {
  description = "create_private_dns_zone = false のとき使う既存ゾーン ID。key はゾーン名"
  type        = map(string)
  default     = {}
}

variable "private_dns_zone_virtual_network_ids" {
  description = "Private DNS Zone にリンクする VNet。key はリンク識別子、value は VNet の ID"
  type        = map(string)
  default     = {}
}
