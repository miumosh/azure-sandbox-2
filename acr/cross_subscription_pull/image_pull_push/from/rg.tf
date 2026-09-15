resource "azurerm_resource_group" "rg" {
  name     = "cross-sub-pull-a-rg"
  location = var.location
}
