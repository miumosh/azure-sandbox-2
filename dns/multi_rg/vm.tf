# ============================================================================
# 疎通 / 名前解決 確認用 VM (RG3)
# ============================================================================

# SSH 鍵は毎回生成してローカルに書き出す (サンドボックス用途)。
# 名前解決の確認は `az vm run-command` で行えるため SSH は必須ではない。
resource "tls_private_key" "vm" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "vm_private_key" {
  filename        = "${path.module}/generated/${local.vm.name}_id_rsa"
  content         = tls_private_key.vm.private_key_openssh
  file_permission = "0600"
}

# ----------------------------------------------------------------------------
# 2025-09-30 の「既定の送信アクセス」廃止により、新規 VNet の VM は明示的な
# 送信経路が無いとインターネットへ出られない。VM エージェント (= run-command)
# が Azure 側と通信できるよう Public IP を NIC に付与する。
# インバウンドは NSG で絞る (var.allowed_client_ips が空なら SSH 許可なし)。
# ----------------------------------------------------------------------------
resource "azurerm_public_ip" "vm" {
  name                = "pip-${local.vm.name}"
  resource_group_name = azurerm_resource_group.this["rg3"].name
  location            = azurerm_resource_group.this["rg3"].location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${local.vm.name}"
  resource_group_name = azurerm_resource_group.this["rg3"].name
  location            = azurerm_resource_group.this["rg3"].location
  tags                = local.tags

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

resource "azurerm_network_interface" "vm" {
  name                = "nic-${local.vm.name}"
  resource_group_name = azurerm_resource_group.this["rg3"].name
  location            = azurerm_resource_group.this["rg3"].location
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.this["rg3"].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = local.vm.name
  resource_group_name = azurerm_resource_group.this["rg3"].name
  location            = azurerm_resource_group.this["rg3"].location
  size                = local.vm.size
  admin_username      = local.vm.admin_username
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.vm.id]

  admin_ssh_key {
    username   = local.vm.admin_username
    public_key = tls_private_key.vm.public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = local.vm.image.publisher
    offer     = local.vm.image.offer
    sku       = local.vm.image.sku
    version   = local.vm.image.version
  }

  # dig / nslookup を使えるようにしておく (Ubuntu 24.04 には既定で入らない)。
  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - bind9-dnsutils
  CLOUDINIT
  )
}
