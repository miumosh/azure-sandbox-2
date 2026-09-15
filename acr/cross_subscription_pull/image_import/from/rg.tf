resource "azurerm_resource_group" "rg" {
  name     = "acr-import-a-rg"
  location = var.location
}
