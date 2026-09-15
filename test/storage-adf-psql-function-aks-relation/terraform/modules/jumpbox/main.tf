# ============================================================================
# jumpbox モジュール
# public IP + SSH でローカルから直接接続する踏み台 VM。
# - PostgreSQL の Private Endpoint へ psql で接続
# - Python Function の zip を pip でビルド
# - func storage(Spoke) の Private Endpoint 経由で zip をアップロード
# 接続元は呼び出し側 (env) の NSG で IP 制限する。
# ============================================================================
resource "azurerm_public_ip" "jumpbox" {
  name                = "${var.jumpbox_name}-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "${var.jumpbox_name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.jumpbox_subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox.id
  }

  tags = var.tags
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                = var.jumpbox_name
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.jumpbox_vm_size
  admin_username      = var.jumpbox_admin_username

  network_interface_ids = [azurerm_network_interface.jumpbox.id]

  # 検証簡略化のためパスワード認証を許可 (接続元は env 側 NSG で IP 制限)。
  admin_password                  = var.jumpbox_admin_password
  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # 起動時にツールを導入: psql クライアント / pip (Function zip のビルド用) / Azure CLI。
  custom_data = base64encode(<<-CLOUD_INIT
    #cloud-config
    package_update: true
    packages:
      - postgresql-client
      - python3-pip
      - python3-venv
    runcmd:
      - curl -sL https://aka.ms/InstallAzureCLIDeb | bash
  CLOUD_INIT
  )

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}
