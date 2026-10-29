# ============================================================================
# 検証用 VM (フローログに記録させるトラフィックの発生源)
#
# ログインはしない。Linux VM の作成に SSH 公開鍵が必須なので生成するが、
# 秘密鍵はファイルにも output にも出さない (state には残るため state はコミットしない)。
# パブリック IP は付けない。
# ============================================================================
resource "tls_private_key" "vm" {
  count = var.create_test_vm ? 1 : 0

  algorithm = "ED25519"
}

resource "azurerm_network_interface" "vm" {
  count = var.create_test_vm ? 1 : 0

  name                = "nic-${local.vm.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }

  tags = local.tags
}

resource "azurerm_linux_virtual_machine" "this" {
  count = var.create_test_vm ? 1 : 0

  name                            = local.vm.name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  size                            = local.vm.size
  admin_username                  = local.vm.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm[0].id]

  admin_ssh_key {
    username   = local.vm.admin_username
    public_key = tls_private_key.vm[0].public_key_openssh
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = local.tags
}
