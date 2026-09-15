resource "azurerm_resource_group" "rg" {
  name     = "acr-import-b-rg"
  location = var.location
}
