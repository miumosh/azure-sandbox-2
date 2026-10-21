# ============================================================
# ソース ACR (A) / 取り込み先 ACR (B) — Premium / 完全プライベート
# ------------------------------------------------------------
# public 無効でも network_rule_bypass_option = "AzureServices"
# (= allow trusted services) により import は通る想定。
# オペレータ端末から *.azurecr.io に到達できないことも合わせて確認する。
# ============================================================
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_container_registry" "src" {
  provider            = azurerm.src
  name                = "${var.name_prefix}src${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.src.name
  location            = azurerm_resource_group.src.location

  sku           = "Premium"
  admin_enabled = false

  public_network_access_enabled = false
  network_rule_bypass_option    = "AzureServices"
}

resource "azurerm_container_registry" "dst" {
  provider            = azurerm.dst
  name                = "${var.name_prefix}dst${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.dst.name
  location            = azurerm_resource_group.dst.location

  sku           = "Premium"
  admin_enabled = false

  public_network_access_enabled = false
  network_rule_bypass_option    = "AzureServices"
}

# ソース ACR に検証用イメージを投入 (public 無効でも ARM 経由の import なら入れられる)。
# 実行するのは terraform を流している管理者の az login コンテキスト。
resource "terraform_data" "seed_image" {
  triggers_replace = [azurerm_container_registry.src.id, var.seed_image]

  provisioner "local-exec" {
    command = "az acr import --name ${azurerm_container_registry.src.name} --subscription ${var.src_subscription_id} --source ${var.seed_image} --image hello-world:latest --force"
  }
}
