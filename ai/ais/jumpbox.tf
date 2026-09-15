# ============================================================================
# 検証用 Jumpbox
# ----------------------------------------------------------------------------
# 閉域化した AI サービスは「VNet の中からしか」検証できない。
# terraform 実行端末からの nslookup / curl では公開 DNS の応答しか見えず、
# PE が効いているかどうかの判定には一切使えない。
#
#   Linux VM (enable_jumpbox) : DNS 解決 / HTTPS 疎通 / 推論 API の確認。
#                               SSH 不要。`az vm run-command` で実行する (verify.sh)。
#   Bastion + Windows VM (enable_bastion)
#                             : AI Foundry ポータルをブラウザで触る場合のみ。
#                               Bastion は起動中つねに課金されるため既定 false。
#
# 2025-09-30 の「既定の送信アクセス」廃止により、新規 VNet の VM は明示的な送信経路が
# 無いとインターネットへ出られない。VM エージェント (= run-command) と
# ポータルの読み込みのために Public IP を NIC に付与する。
# インバウンドは NSG で塞ぐ (既定規則で Internet からの受信は拒否)。
# ============================================================================
locals {
  jumpbox_count = var.enable_jumpbox ? 1 : 0
  bastion_count = var.enable_bastion ? 1 : 0
}

# ---- Linux 検証 VM ---------------------------------------------------------
resource "tls_private_key" "jumpbox" {
  count = local.jumpbox_count

  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "jumpbox_private_key" {
  count = local.jumpbox_count

  filename        = "${path.module}/generated/${local.jumpbox.name}_id_rsa"
  content         = tls_private_key.jumpbox[0].private_key_openssh
  file_permission = "0600"
}

resource "azurerm_network_security_group" "jumpbox" {
  count = local.jumpbox_count

  name                = "nsg-${local.jumpbox.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  # 既定で Internet からの受信は拒否される。SSH したい場合のみ許可 IP を開ける。
  # 検証は az vm run-command で行えるため通常は不要。
  dynamic "security_rule" {
    for_each = length(var.allowed_client_ips) > 0 ? [1] : []
    content {
      name                       = "AllowSshFromClient"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefixes    = var.allowed_client_ips
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_public_ip" "jumpbox" {
  count = local.jumpbox_count

  name                = "pip-${local.jumpbox.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "jumpbox" {
  count = local.jumpbox_count

  name                = "nic-${local.jumpbox.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.this["jumpbox"].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox[0].id
  }
}

resource "azurerm_network_interface_security_group_association" "jumpbox" {
  count = local.jumpbox_count

  network_interface_id      = azurerm_network_interface.jumpbox[0].id
  network_security_group_id = azurerm_network_security_group.jumpbox[0].id
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  count = local.jumpbox_count

  name                  = local.jumpbox.name
  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  size                  = local.jumpbox.size
  admin_username        = local.jumpbox.admin_username
  network_interface_ids = [azurerm_network_interface.jumpbox[0].id]
  tags                  = local.tags

  # Entra ID 認証を PE 経由で検証するためのマネージド ID。
  # キーを az vm run-command のスクリプトに埋め込まずに済む、という実利もある。
  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = local.jumpbox.admin_username
    public_key = tls_private_key.jumpbox[0].public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = local.jumpbox.image.publisher
    offer     = local.jumpbox.image.offer
    sku       = local.jumpbox.image.sku
    version   = local.jumpbox.image.version
  }

  # nslookup / dig は Ubuntu 24.04 に既定で入らないため入れておく。
  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - bind9-dnsutils
      - curl
  CLOUDINIT
  )
}

# ---- Bastion + Windows VM (ポータル手動確認用) --------------------------------
resource "azurerm_public_ip" "bastion" {
  count = local.bastion_count

  name                = "pip-${local.bastion_name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "this" {
  count = local.bastion_count

  name                = local.bastion_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  tags                = local.tags

  ip_configuration {
    name                 = "ipconfig1"
    subnet_id            = azurerm_subnet.this["bastion"].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}

# ai.azure.com / portal.azure.com をブラウザで開くため、送信経路として Public IP を付ける。
# 受信は NSG 既定規則で Internet からは拒否され、Bastion (VNet 内) からのみ RDP が通る。
resource "azurerm_public_ip" "windows_jumpbox" {
  count = local.bastion_count

  name                = "pip-${local.windows_jumpbox.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "windows_jumpbox" {
  count = local.bastion_count

  name                = "nic-${local.windows_jumpbox.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.this["jumpbox"].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.windows_jumpbox[0].id
  }
}

resource "azurerm_windows_virtual_machine" "jumpbox" {
  count = local.bastion_count

  name                  = local.windows_jumpbox.name
  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  size                  = local.windows_jumpbox.size
  admin_username        = local.windows_jumpbox.admin_username
  admin_password        = var.windows_jumpbox_admin_password
  network_interface_ids = [azurerm_network_interface.windows_jumpbox[0].id]
  tags                  = local.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = local.windows_jumpbox.image.publisher
    offer     = local.windows_jumpbox.image.offer
    sku       = local.windows_jumpbox.image.sku
    version   = local.windows_jumpbox.image.version
  }

  lifecycle {
    precondition {
      condition     = var.windows_jumpbox_admin_password != null
      error_message = "enable_bastion = true の場合は windows_jumpbox_admin_password を指定してください。"
    }
  }
}

# ---- probe VM への権限付与 ---------------------------------------------------
# 「ネットワークは通ったが認証で落ちた」を切り分けられるようにしておく。
# これが無いと 403 がネットワーク遮断なのか権限不足なのか判別できない。
resource "azurerm_role_assignment" "jumpbox_cognitive" {
  for_each = var.enable_jumpbox ? local.cognitive_accounts : {}

  scope                = module.cognitive[each.key].id
  role_definition_name = "Cognitive Services User"
  principal_id         = azurerm_linux_virtual_machine.jumpbox[0].identity[0].principal_id
}

# Hub (AML workspace) のデータ面を叩けるようにする。
# これが無いと Hub の 403 が「ネットワーク遮断」なのか「権限不足」なのか区別できない。
resource "azurerm_role_assignment" "jumpbox_hub" {
  count = var.enable_jumpbox && var.enable_foundry_hub ? 1 : 0

  scope                = azurerm_ai_foundry.this[0].id
  role_definition_name = "AzureML Data Scientist"
  principal_id         = azurerm_linux_virtual_machine.jumpbox[0].identity[0].principal_id
}

# AI Foundry v2 プロジェクトのデータ面 (ai.azure.com が叩く API) 用。
# "Azure AI User" というロールは存在しない (2026-09 時点)。Foundry 系は
# Azure AI Developer / Azure AI Administrator。
resource "azurerm_role_assignment" "jumpbox_aiservices_user" {
  count = var.enable_jumpbox ? 1 : 0

  scope                = module.cognitive["aiservices"].id
  role_definition_name = "Azure AI Developer"
  principal_id         = azurerm_linux_virtual_machine.jumpbox[0].identity[0].principal_id
}

# Key Vault に Secret が実際に登録されるか (= AI Foundry の connection 挙動) を
# VNet 内から確認するための権限。Key Vault は public 無効なので PE 経由でしか読めない。
resource "azurerm_role_assignment" "jumpbox_key_vault" {
  count = var.enable_jumpbox && var.enable_foundry_hub ? 1 : 0

  scope                = azurerm_key_vault.this[0].id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.jumpbox[0].identity[0].principal_id
}
