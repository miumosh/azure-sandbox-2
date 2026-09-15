resource "azurerm_resource_group" "rg" {
  name     = "certcsi-rg"
  location = var.location
}
