# ============================================================================
# 環境設定値 (locals で集中管理)
# - 各リソースは local.<plural>.<key>.<attr> 形式で参照する。
# ============================================================================
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  location = var.location
  prefix   = "dnsmrg"
  suffix   = random_string.suffix.result

  tags = {
    project = "private-dns-multi-rg"
    env     = "sandbox"
  }

  # ---- リソースグループ ---------------------------------------------------
  # rg1 / rg2 : 同名 Private DNS ゾーン + Private Endpoint をそれぞれ持つ
  # rg3       : 名前解決の確認用 VM
  resource_groups = {
    rg1 = { name = "${local.prefix}-rg1", purpose = "private dns zone + PE (A)" }
    rg2 = { name = "${local.prefix}-rg2", purpose = "private dns zone + PE (B)" }
    rg3 = { name = "${local.prefix}-rg3", purpose = "test vm" }
  }

  # Private DNS ゾーン / PE を持つ RG (rg3 は VM 専用なのでゾーンを持たない)
  resource_groups_with_zone = {
    rg1 = local.resource_groups.rg1
    rg2 = local.resource_groups.rg2
  }

  # ---- ネットワーク -------------------------------------------------------
  # アドレス空間は 3 VNet でフルメッシュにピアリングするため重複させない。
  vnets = {
    rg1 = {
      name          = "vnet-${local.prefix}-1"
      address_space = ["10.10.0.0/16"]
      subnet_name   = "snet-pe"
      subnet_prefix = ["10.10.1.0/24"]
    }
    rg2 = {
      name          = "vnet-${local.prefix}-2"
      address_space = ["10.20.0.0/16"]
      subnet_name   = "snet-pe"
      subnet_prefix = ["10.20.1.0/24"]
    }
    rg3 = {
      name          = "vnet-${local.prefix}-3"
      address_space = ["10.30.0.0/16"]
      subnet_name   = "snet-vm"
      subnet_prefix = ["10.30.1.0/24"]
    }
  }

  # フルメッシュのピアリング (双方向 = 6 リンク)。
  # 検証の要点: ピアリングを張っても Private DNS の名前解決は伝播しない。
  # 名前解決はあくまで「VNet と DNS ゾーンのリンク」だけで決まる。
  peerings = {
    "1-to-2" = { from = "rg1", to = "rg2" }
    "2-to-1" = { from = "rg2", to = "rg1" }
    "1-to-3" = { from = "rg1", to = "rg3" }
    "3-to-1" = { from = "rg3", to = "rg1" }
    "2-to-3" = { from = "rg2", to = "rg3" }
    "3-to-2" = { from = "rg3", to = "rg2" }
  }

  # ---- Private Endpoint の対象 -------------------------------------------
  # Blob Storage を PE の題材にする (privatelink.blob.core.windows.net)。
  # public_network_access_enabled = false にして「PE 経由でしか到達できない」
  # 状態を作り、名前解決が効かない = 到達不能 であることを分かりやすくする。
  storage_accounts = {
    rg1 = { name = "st${local.prefix}1${local.suffix}" }
    rg2 = { name = "st${local.prefix}2${local.suffix}" }
  }

  # ---- Private DNS ゾーン -------------------------------------------------
  # RG1 / RG2 に "まったく同じ名前" のゾーンを作る。これが検証 (1) の対象。
  private_dns_zone_name = "privatelink.blob.core.windows.net"

  # 検証 (3) 用: 両ゾーンに "同じレコード名" で "異なる IP" の A レコードを置く。
  # ストレージ名はグローバル一意で FQDN が別々になってしまうため、
  # 同一 FQDN が VNet ごとに別の値へ解決されることを見るには手動レコードが要る。
  conflict_record_name = "conflict"
  conflict_records = var.create_conflict_records ? {
    rg1 = "10.10.99.99"
    rg2 = "10.20.99.99"
  } : {}

  conflict_fqdn = "${local.conflict_record_name}.${local.private_dns_zone_name}"

  # ---- 各 VNet へのゾーンリンク ------------------------------------------
  # VNet1 -> RG1 のゾーン、VNet2 -> RG2 のゾーンは固定。
  # VNet3 (VM 側) は var.vm_vnet_dns_link で切り替える。
  vm_vnet_links = {
    rg1  = ["rg1"]
    rg2  = ["rg2"]
    both = ["rg1", "rg2"]
    none = []
  }[var.vm_vnet_dns_link]

  # zone key => その zone を VNet3 にリンクするか
  vnet3_links = { for z in local.vm_vnet_links : z => z }

  # ---- 検証 VM ------------------------------------------------------------
  vm = {
    name           = "vm-${local.prefix}-test"
    size           = "Standard_B1s"
    admin_username = "azureuser"
    image = {
      publisher = "Canonical"
      offer     = "ubuntu-24_04-lts"
      sku       = "server"
      version   = "latest"
    }
  }
}
