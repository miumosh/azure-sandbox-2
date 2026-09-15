resource "azurerm_resource_group" "rg" {
  name     = "cross-sub-pull-b-rg"
  location = var.location
}
