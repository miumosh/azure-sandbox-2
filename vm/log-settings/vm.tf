# ============================================================================
# 監視対象の Linux VM (Ubuntu 24.04) + Azure Monitor Agent
#
# ログインはしない。Linux VM の作成に SSH 公開鍵が必須なので生成するが、
# 秘密鍵はファイルにも output にも出さない (state には残るため state はコミットしない)。
# ============================================================================
resource "tls_private_key" "vm" {
  algorithm = "ED25519"
}

resource "azurerm_network_interface" "vm" {
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
  name                            = local.vm.name
  resource_group_name             = azurerm_resource_group.this.name
  location                        = azurerm_resource_group.this.location
  size                            = local.vm.size
  admin_username                  = local.vm.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]

  admin_ssh_key {
    username   = local.vm.admin_username
    public_key = tls_private_key.vm.public_key_openssh
  }

  # AMA はこの ID で Azure Monitor に認証する (拡張機能の設定で別の ID を指定しない場合の既定)
  identity {
    type = "SystemAssigned"
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

  custom_data = base64encode(templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    log_dir  = local.app_log.directory
    log_path = "${local.app_log.directory}/${local.app_log.file_name}"
  }))

  tags = local.tags
}

# Azure Monitor Agent (Linux)。
# 拡張機能自体には送信先の設定は無く、DCR を関連付ける (dcr.tf) ことで収集対象と送信先が決まる。
resource "azurerm_virtual_machine_extension" "ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.this.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  # 新しいバージョンが出たときにプラットフォーム側で自動更新させる
  automatic_upgrade_enabled = true

  tags = local.tags
}
