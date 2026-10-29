# ============================================================================
# 環境設定値 (locals で集中管理)
# ============================================================================
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  location = var.location
  prefix   = "flowlog"
  suffix   = random_string.suffix.result

  tags = {
    project = "vnet-flowlog"
    env     = "sandbox"
  }

  resource_group_name = "rg-${local.prefix}-${local.suffix}"

  # ---- Network Watcher (既存を参照) -----------------------------------------
  network_watcher = {
    name                = coalesce(var.network_watcher.name, "NetworkWatcher_${local.location}")
    resource_group_name = var.network_watcher.resource_group_name
  }

  # ---- ネットワーク ----------------------------------------------------------
  vnet = {
    name          = "vnet-${local.prefix}-${local.suffix}"
    address_space = ["10.10.0.0/16"]
  }
  subnet = {
    name             = "snet-vm"
    address_prefixes = ["10.10.1.0/24"]
  }
  nsg = {
    name = "nsg-${local.prefix}-${local.suffix}"
  }

  # ---- フローログ保存先ストレージ --------------------------------------------
  storage = {
    # ストレージアカウント名は 3-24 文字の英小文字と数字のみ
    name = "stfl${local.suffix}"
  }

  # ---- フローログ ------------------------------------------------------------
  flow_log = {
    name = "fl-${local.vnet.name}"
    # Blob に残す日数 (Network Watcher がライフサイクル管理ルールを作る)
    retention_days = 7
  }

  # ---- 検証用 VM ---------------------------------------------------------------
  vm = {
    name           = "vm-${local.prefix}-${local.suffix}"
    size           = "Standard_B1s"
    admin_username = "azureuser"
  }
}
