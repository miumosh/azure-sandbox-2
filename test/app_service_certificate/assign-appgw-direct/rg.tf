resource "azurerm_resource_group" "rg" {
  name     = "certdirect-rg"
  location = var.location
}
