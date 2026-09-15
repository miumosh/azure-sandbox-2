# ============================================================================
# Hub env 入力変数 (機微情報 / 環境固有値 / cross-subscription 参照のみ)
# - それ以外の構成値は locals.tf で object 管理する。
# ============================================================================

variable "subscription_id" {
  description = "Hub サブスクリプション (ci00-hub-subscription) の ID"
  type        = string
}

variable "allowed_upload_ip" {
  description = "Storage Explorer からのアクセスを許可するグローバル IP (裸 IP / CIDR)"
  type        = string
}

variable "jumpbox_admin_password" {
  description = "踏み台 VM の管理者パスワード"
  type        = string
  sensitive   = true
}

variable "acr_public_network_access_enabled" {
  description = "ACR の public network access。push 時のみ true にする (既定 false = 閉域)"
  type        = bool
  default     = false
}

variable "ingestion_trigger_activated" {
  description = "取り込みトリガー trg_csv_uploaded を有効化するか (テスト時 false / 運用時 true)"
  type        = bool
  default     = true
}

# ---- Spoke 側リソースへの参照 (cross-subscription) ---------------------------
# spoke-subscription を先に apply し、その output を tfvars 経由で渡す。
# 未設定の間は VNet ピアリング / ADF→PostgreSQL 連携は作成されない。

variable "spoke_vnet_id" {
  description = "Spoke VNet のリソース ID (VNet ピアリング先)。未設定ならピアリングは作成しない"
  type        = string
  default     = ""
}

variable "psql_server_id" {
  description = "Spoke の PostgreSQL サーバーのリソース ID (ADF Managed Private Endpoint 接続先)"
  type        = string
  default     = ""
}

variable "psql_fqdn" {
  description = "Spoke の PostgreSQL サーバー FQDN (ADF リンクサービスの接続先)"
  type        = string
  default     = ""
}

variable "aks_kubelet_object_id" {
  description = "Spoke の AKS kubelet マネージドID object_id (ACR の AcrPull 付与先)。spoke output から設定"
  type        = string
  default     = ""
}
