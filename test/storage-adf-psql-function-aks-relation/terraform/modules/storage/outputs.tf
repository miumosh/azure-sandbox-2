output "id" {
  value = azurerm_storage_account.this.id
}

output "name" {
  value = azurerm_storage_account.this.name
}

output "upload_container_name" {
  value = azurerm_storage_container.upload.name
}

output "archive_container_name" {
  value = azurerm_storage_container.archive.name
}

output "upload_container_sas_url" {
  description = "Storage Explorer に貼り付けて upload コンテナへ接続するための SAS URL"
  value       = "https://${azurerm_storage_account.this.name}.blob.core.windows.net/${azurerm_storage_container.upload.name}?${data.azurerm_storage_account_blob_container_sas.upload.sas}"
  sensitive   = true
}
