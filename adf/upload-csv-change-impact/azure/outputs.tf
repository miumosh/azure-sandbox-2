# run_adf.py / setup-db.sh が terraform output -json で読む値
output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "storage_account_name" {
  value = azurerm_storage_account.main.name
}

output "upload_container" {
  value = azurerm_storage_container.upload.name
}

output "archive_container" {
  value = azurerm_storage_container.archive.name
}

output "data_factory_id" {
  value = azurerm_data_factory.main.id
}

output "pipeline_name" {
  value = azurerm_data_factory_pipeline.ingest.name
}

output "src_csv_dataset" {
  description = "デプロイ中の ds_src_csv 定義 (after / before)"
  value       = var.src_csv_dataset
}

output "psql_fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "psql_admin_login" {
  value = local.psql.admin_login
}

output "psql_database" {
  value = azurerm_postgresql_flexible_server_database.app.name
}
