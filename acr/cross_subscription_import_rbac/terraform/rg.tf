resource "azurerm_resource_group" "src" {
  provider = azurerm.src
  name     = "acr-import-rbac-a-rg"
  location = var.location
}

resource "azurerm_resource_group" "dst" {
  provider = azurerm.dst
  name     = "acr-import-rbac-b-rg"
  location = var.location
}
