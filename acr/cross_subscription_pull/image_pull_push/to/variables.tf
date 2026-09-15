variable "subscription_id" {
  description = "サブスクリプション B (Pull する側 / 取り込み先 ACR) の Subscription ID"
  type        = string
}

variable "source_subscription_id" {
  description = "サブスクリプション A (ソース側) の Subscription ID。alias provider 用"
  type        = string
}

variable "location" {
  description = "Azure Region (A・B 共通)"
  type        = string
  default     = "japaneast"
}

variable "acr_name" {
  description = "取り込み先 ACR 名 (グローバル一意・英数字 5-50 文字)"
  type        = string
}

variable "runner_identity_name" {
  description = "Runner VM に割り当てる User Assigned Identity 名"
  type        = string
  default     = "acr-pull-runner"
}

# ----- B 側ネットワーク -----
variable "vnet_address_space" {
  description = "B 側 VNet のアドレス空間 (A 側と重複しないこと)"
  type        = list(string)
  default     = ["10.20.0.0/16"]
}

variable "pe_subnet_prefix" {
  description = "B 側 Private Endpoint 用サブネットの CIDR"
  type        = list(string)
  default     = ["10.20.1.0/24"]
}

variable "vm_subnet_prefix" {
  description = "Runner VM 用サブネットの CIDR"
  type        = list(string)
  default     = ["10.20.2.0/24"]
}

# ----- Runner VM -----
variable "vm_size" {
  description = "Runner VM のサイズ"
  type        = string
  default     = "Standard_B2ms"
}

variable "vm_admin_username" {
  description = "Runner VM の管理者ユーザー名"
  type        = string
  default     = "azureuser"
}

variable "vm_admin_password" {
  description = "Runner VM の管理者パスワード"
  type        = string
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  description = "Runner VM への SSH を許可する送信元 CIDR (例: x.x.x.x/32)"
  type        = string
}

# ----- ソース (A) 情報: from の output をそのまま渡す -----
variable "source_acr_login_server" {
  description = "ソース ACR (A) のログインサーバー (例: xxx.azurecr.io)。from output: source_acr_login_server"
  type        = string
}

variable "source_acr_id" {
  description = "ソース ACR (A) の Resource ID。AcrPull 付与に使用。from output: source_acr_id"
  type        = string
}

variable "source_rg_name" {
  description = "A 側リソースグループ名。共有 DNS ゾーンへの VNet リンク作成に使用。from output: source_rg_name"
  type        = string
}

variable "source_vnet_id" {
  description = "A 側 VNet の Resource ID。VNet ピアリングに使用。from output: source_vnet_id"
  type        = string
}

variable "source_vnet_name" {
  description = "A 側 VNet 名。VNet ピアリングに使用。from output: source_vnet_name"
  type        = string
}

variable "source_dns_zone_id" {
  description = "共有 Private DNS ゾーンの Resource ID。B の PE / VNet リンクで参照。from output: source_dns_zone_id"
  type        = string
}

variable "sample_image" {
  description = "動作確認で pull/push するイメージ (repository:tag)。output コマンド組み立て用"
  type        = string
  default     = "hello-world:latest"
}
