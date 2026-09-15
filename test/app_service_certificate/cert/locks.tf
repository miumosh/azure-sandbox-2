# ===========================================================================
# 削除ロック
#
# 【なぜ必要か — 実検証で判明】
# 公式ドキュメントには「App Service Certificate の作成プロセスは KeyVault に
# AppServiceCertificateLock という削除ロックを作る」と書かれている。
# しかしこれは **ポータルのウィザード経由の場合だけ** で、
# ARM API / Terraform で作ると **ロックは付かない**（実測で確認済み: az lock list が空だった）。
#
# App Service Certificate は PFX を直接ダウンロードさせてくれず、
# **KeyVault が唯一の受け渡し口**。つまり KeyVault を消すと証明書を取り出す手段が消える。
# また証明書オーダー自体の削除は **証明書の失効を意味し、取り消し不可**。
#
# → どちらも CanNotDelete でロックする。
#
# 【注意】このロックは "Terraform の外からの誤削除" を防ぐもの。
# `terraform destroy` はロック → 対象リソースの順に消すため、destroy は止められない。
# 本当に守りたいなら Terraform 管理から外す（= az CLI 運用にする）方が確実。
#   → az_cli_pattern.md 参照
# ===========================================================================

# 証明書の実体 (PFX) の置き場。ここを消すと証明書を取り出せなくなる。
resource "azurerm_management_lock" "key_vault" {
  name       = "AppServiceCertificateLock" # ポータルが付けるロック名に合わせる
  scope      = azurerm_key_vault.this.id
  lock_level = "CanNotDelete"
  notes      = "App Service Certificate の実体は KeyVault にしか存在しない。削除すると復旧不可。"
}

# 証明書オーダー本体。削除 = 失効（取り消し不可・有料）。
resource "azurerm_management_lock" "cert_order" {
  count = var.cert_source == "app_service_order" ? 1 : 0

  name       = "CertOrderDoNotDelete"
  scope      = azurerm_app_service_certificate_order.this[0].id
  lock_level = "CanNotDelete"
  notes      = "削除すると証明書が失効し、取り消せない。再購入には再課金が必要。"
}
