# ============================================================================
# ルート 入力変数
# - 設定値は原則 locals.tf に置き、機微情報 / 環境依存値のみここで受け取る。
# ============================================================================
variable "subscription_id" {
  description = "デプロイ先の Subscription ID (検証は単一サブスクリプション内で完結する)"
  type        = string
}

variable "location" {
  description = "全リソースのリージョン"
  type        = string
  default     = "japaneast"
}

variable "allowed_client_ips" {
  description = <<-EOT
    検証 VM (RG3) への SSH インバウンドを許可するグローバル IP (裸 IP または CIDR)。
    空リストの場合 SSH の許可ルールを作らない。
    名前解決の確認は `az vm run-command` 経由で行えるため、通常は空のままでよい。
  EOT
  type        = list(string)
  default     = []
}

variable "vm_vnet_dns_link" {
  description = <<-EOT
    検証 VM が居る VNet3 に、どちらの Private DNS ゾーンをリンクするかの切り替え。
    この検証の主役となるスイッチ。

      "rg1"  : RG1 のゾーンのみリンク (既定)。VM は RG1 側の PE だけ名前解決できる。
      "rg2"  : RG2 のゾーンのみリンク。同じ FQDN が RG2 側の PE に解決されることを確認する。
      "both" : 同名ゾーンを 2 つとも VNet3 にリンクしようとする。
               Azure は「同名ゾーンの同一 VNet への複数リンク」を許可しないため
               apply が失敗するはず — 衝突の有無を実証するためのモード。
      "none" : どちらもリンクしない。ピアリングだけでは名前解決が伝播しないことの確認用。
  EOT
  type        = string
  default     = "rg1"

  validation {
    condition     = contains(["rg1", "rg2", "both", "none"], var.vm_vnet_dns_link)
    error_message = "vm_vnet_dns_link は rg1 / rg2 / both / none のいずれかを指定してください。"
  }
}

variable "create_conflict_records" {
  description = <<-EOT
    両ゾーンに同名 / 別 IP の A レコード (conflict.privatelink.blob.core.windows.net) を
    作成するか。

    false にすると、各ゾーンには自分の Private Endpoint が登録した A レコード
    (ストレージ名 = グローバル一意) しか存在せず、2 ゾーン間でレコード名は一切重複しない。
    この状態でも同名ゾーンの二重リンクが拒否されるか (= 判定がゾーン名前空間単位か、
    レコード単位か) を確認するためのスイッチ。
  EOT
  type        = bool
  default     = true
}
