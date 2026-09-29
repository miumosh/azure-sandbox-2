# ============================================================================
# 設定値 (object 型の locals で集中管理)
# ============================================================================
locals {
  location = "japaneast"
  prefix   = "csvenc"
  suffix   = random_string.suffix.result

  tags = {
    project = "upload-csv-change-impact"
    env     = "test"
  }

  resource_group_name = "${local.prefix}-rg"

  storage_account = {
    name              = "${local.prefix}st${local.suffix}"
    upload_container  = "upload"
    archive_container = "archive"
  }

  psql = {
    name        = "${local.prefix}-psql-${local.suffix}"
    admin_login = "psqladmin"
    database    = "appdb" # 本番と同じ DB 名
  }

  data_factory_name = "${local.prefix}-adf-${local.suffix}"

  # 本番のパイプライン定義 (pipeline.json / validation.sql / ds_src_csv 以外の dataset) をそのまま読む
  pipeline_dir = "${path.module}/../../../test/storage-adf-psql-function-aks-relation/terraform/envs/hub-subscription/files/adf_pipeline/customer_info_registration"

  # ds_src_csv だけは本ディレクトリの変更後 / 変更前定義から選ぶ
  src_csv_dataset_file = "${path.module}/../datasets/ds_src_csv.${var.src_csv_dataset}.json"

  # Dataset: name / type / linked service / typeProperties(JSON 文字列)。本番 hub env の locals と同じ構成。
  datasets = {
    src_csv = {
      name           = "ds_src_csv"
      type           = "DelimitedText"
      linked_service = "blob"
      type_properties_json = templatefile(local.src_csv_dataset_file, {
        upload_container = local.storage_account.upload_container
      })
    }
    customer_info_landing = {
      name                 = "ds_customer_info_landing"
      type                 = "AzurePostgreSqlTable"
      linked_service       = "psql"
      type_properties_json = file("${local.pipeline_dir}/datasets/ds_customer_info_landing.json")
    }
    customer_info_error = {
      name                 = "ds_customer_info_error"
      type                 = "AzurePostgreSqlTable"
      linked_service       = "psql"
      type_properties_json = file("${local.pipeline_dir}/datasets/ds_customer_info_error.json")
    }
    customer_info_production = {
      name                 = "ds_customer_info_production"
      type                 = "AzurePostgreSqlTable"
      linked_service       = "psql"
      type_properties_json = file("${local.pipeline_dir}/datasets/ds_customer_info_production.json")
    }
    archive_success_csv = {
      name           = "ds_archive_success_csv"
      type           = "DelimitedText"
      linked_service = "blob"
      type_properties_json = templatefile("${local.pipeline_dir}/datasets/ds_archive_success_csv.json", {
        archive_container = local.storage_account.archive_container
      })
    }
    archive_error_csv = {
      name           = "ds_archive_error_csv"
      type           = "DelimitedText"
      linked_service = "blob"
      type_properties_json = templatefile("${local.pipeline_dir}/datasets/ds_archive_error_csv.json", {
        archive_container = local.storage_account.archive_container
      })
    }
  }
}
