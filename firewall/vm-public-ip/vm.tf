# ============================================================================
# サービス稼働 VM
#
# NIC に インスタンスレベル Public IP (ILPIP) を付ける。ILPIP がある NIC は
# 「next hop = Internet」のルートに乗った通信の SNAT にこの IP を使う。
# = 宛先A/B 向けアウトバウンドも、インバウンドの戻りも、同じ Public IP になる。
# ============================================================================
resource "tls_private_key" "vm" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "vm_private_key" {
  filename        = "${path.module}/generated/${local.vm.name}_id_rsa"
  content         = tls_private_key.vm.private_key_openssh
  file_permission = "0600"
}

resource "azurerm_public_ip" "vm" {
  name                = "pip-${local.vm.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-${local.vm.name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = local.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = local.vm.name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
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

  # 疎通確認用に nginx を上げる。どの経路で出たかを見る curl も入れておく。
  custom_data = base64encode(<<-CLOUDINIT
    #cloud-config
    package_update: true
    packages:
      - nginx
      - curl
      - traceroute
    runcmd:
      - [ systemctl, enable, --now, nginx ]
  CLOUDINIT
  )

  # ルートテーブルが付く前に起動すると、cloud-init の apt が
  # Firewall のルールではなく既定経路で出てしまい検証がぶれる。
  depends_on = [azurerm_subnet_route_table_association.vm]
}
