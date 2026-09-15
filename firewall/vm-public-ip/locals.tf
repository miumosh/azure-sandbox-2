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
  prefix   = "fwpip"
  suffix   = random_string.suffix.result

  tags = {
    project = "firewall-vm-public-ip"
    env     = "sandbox"
  }

  # ---- ネットワーク -------------------------------------------------------
  # AzureFirewallSubnet は名前固定 / 最小 /26。
  # AzureFirewallManagementSubnet は Basic SKU (強制トンネル時も) で必須。
  vnet = {
    name          = "vnet-${local.prefix}"
    address_space = ["10.0.0.0/16"]
  }

  subnets = {
    firewall = { name = "AzureFirewallSubnet", prefix = "10.0.0.0/26" }
    fw_mgmt  = { name = "AzureFirewallManagementSubnet", prefix = "10.0.0.64/26" }
    vm       = { name = "snet-vm", prefix = "10.0.1.0/24" }
  }

  # Basic SKU のときだけ管理用サブネットを作る
  firewall_needs_mgmt_subnet = var.firewall_sku_tier == "Basic"

  # ---- ルーティング設計 ---------------------------------------------------
  # snet-vm に付けるルートテーブルの中身。優先順位は「最長プレフィックス一致」
  # なので、個別ルート (/32〜/24 や Service Tag) が 0.0.0.0/0 より必ず勝つ。
  #
  #   宛先                      next hop            意図
  #   ------------------------  ------------------  --------------------------
  #   0.0.0.0/0                 VirtualAppliance    既定は Firewall 経由
  #   var.direct_destinations   Internet            宛先A/B は Public IP 直行
  #   var.inbound_clients       Internet            インバウンドの戻りを対称化
  #
  # なお 168.63.129.16 (DHCP / DNS / VM Agent 用の Azure 仮想パブリック IP) は
  # UDR を作ろうとすると AddressPrefixInRestrictedAddressSpace で拒否される。
  # 制限アドレス空間としてプラットフォーム側で処理され UDR の影響を受けないため、
  # 0.0.0.0/0 を Firewall に向けても素通しされる。明示ルートは不要。

  direct_routes = merge(
    { for k, v in var.direct_destinations : "direct-${k}" => v },
    { for k, v in var.inbound_clients : "return-${k}" => v },
  )

  # ---- Firewall で許可するアウトバウンド (OS Update / ツール取得) ---------
  # 宛先A/B と インバウンド戻りはルートで迂回するので、ここには載せない。
  fw_allowed_fqdns = [
    # Ubuntu APT
    "azure.archive.ubuntu.com",
    "archive.ubuntu.com",
    "security.ubuntu.com",
    "changelogs.ubuntu.com",
    "esm.ubuntu.com",
    "motd.ubuntu.com",
    # snap
    "api.snapcraft.io",
    "*.snapcraftcontent.com",
    # 代表的なツール取得先
    "github.com",
    "*.githubusercontent.com",
    "packages.microsoft.com",
    "*.docker.io",
    "*.docker.com",
    # 経路検証用: Firewall 経由で出たときの送信元 IP を確認する
    "ifconfig.me",
  ]

  # ---- 検証 VM ------------------------------------------------------------
  vm = {
    name           = "vm-${local.prefix}"
    size           = "Standard_B2s"
    admin_username = "azureuser"
    image = {
      publisher = "Canonical"
      offer     = "ubuntu-24_04-lts"
      sku       = "server"
      version   = "latest"
    }
  }
}
