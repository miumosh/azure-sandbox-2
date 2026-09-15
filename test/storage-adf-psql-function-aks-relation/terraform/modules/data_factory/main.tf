# ============================================================================
# data_factory モジュール
# Managed VNet + Managed Private Endpoint で Storage(Hub) / PostgreSQL(Spoke) に
# プライベート接続する ADF。取込パイプライン (Copy -> Script -> Copy×2) 一式。
# - RBAC / MPE / Linked Service / Dataset / Trigger は object マップで for_each。
#   各リソースの name は呼び出し元 locals の明示 name フィールドから取る (each.value.name)。
# ============================================================================
resource "azurerm_data_factory" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name

  managed_virtual_network_enabled = true
  public_network_enabled          = false

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# AutoResolveIntegrationRuntime を Managed VNet で動作させる
resource "azurerm_data_factory_integration_runtime_azure" "managed" {
  name                    = "ManagedVnetIR"
  data_factory_id         = azurerm_data_factory.this.id
  location                = "AutoResolve"
  virtual_network_enabled = true
  compute_type            = "General"
  core_count              = var.integration_runtime_core_count
  time_to_live_min        = 0
}

# ADF MI へのロール割当 (principal は ADF 自身の MI)
resource "azurerm_role_assignment" "this" {
  for_each = var.role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role_definition_name
  principal_id         = azurerm_data_factory.this.identity[0].principal_id
}

# Managed Private Endpoint (Storage Blob / PostgreSQL など)
resource "azurerm_data_factory_managed_private_endpoint" "this" {
  for_each = var.managed_private_endpoints

  name               = each.value.name
  data_factory_id    = azurerm_data_factory.this.id
  target_resource_id = each.value.target_resource_id
  subresource_name   = each.value.subresource_name
}

# linked_services を kind ごとに分割 (リソースの for_each から条件式を分離し可読性を上げる)。
locals {
  blob_linked_services = { for k, v in var.linked_services : k => v if v.kind == "blob" }
  psql_linked_services = { for k, v in var.linked_services : k => v if v.kind == "psql" }
}

# Linked Service: Azure Blob Storage (MSI 認証)。linked_services のうち kind="blob" を作成。
resource "azurerm_data_factory_linked_service_azure_blob_storage" "this" {
  for_each = local.blob_linked_services

  name                     = each.value.name
  data_factory_id          = azurerm_data_factory.this.id
  use_managed_identity     = true
  service_endpoint         = each.value.service_endpoint
  integration_runtime_name = azurerm_data_factory_integration_runtime_azure.managed.name

  depends_on = [
    azurerm_role_assignment.this,
    azurerm_data_factory_managed_private_endpoint.this,
  ]
}

# Linked Service: PostgreSQL (azapi で V2/MSI JSON を直接投入。azurerm #29379 回避)。
# linked_services のうち kind="psql" を作成。
resource "azapi_resource" "psql_linked_service" {
  for_each = local.psql_linked_services

  type      = "Microsoft.DataFactory/factories/linkedservices@2018-06-01"
  name      = each.value.name
  parent_id = azurerm_data_factory.this.id
  # azapi 同梱スキーマが PostgreSQL Linked Service V2 (version=2.0 + MSI 認証) の body を
  # 未カバーのため検証を無効化する。azapi 既定は true で、ここは意図的な特例。
  schema_validation_enabled = false

  body = {
    properties = {
      type        = "AzurePostgreSql"
      version     = "2.0"
      annotations = []
      typeProperties = {
        server             = each.value.server
        port               = each.value.port
        database           = each.value.database
        sslMode            = each.value.ssl_mode # 0=Disable 1=Allow 2=Prefer 3=Require 4=VerifyCA 5=VerifyFull
        authenticationType = each.value.authentication_type
      }
      connectVia = {
        referenceName = azurerm_data_factory_integration_runtime_azure.managed.name
        type          = "IntegrationRuntimeReference"
      }
    }
  }

  depends_on = [
    azurerm_data_factory_managed_private_endpoint.this,
  ]
}

# Linked Service 名を種別横断で 1 つの map に集約 (dataset から linked_service_key で引く)。
# blob/psql どちらの LS も参照できる多態性と、dataset -> linked service の依存エッジ捕捉の
# 両方をこの 1 マップで解いている (ハードコード文字列にすると依存追跡が切れるため集約のまま保持)。
locals {
  linked_service_names = merge(
    { for k, ls in azurerm_data_factory_linked_service_azure_blob_storage.this : k => ls.name },
    { for k, ls in azapi_resource.psql_linked_service : k => ls.name },
  )
}

# Datasets (Blob/DelimitedText も PostgreSQL/Table も統合。1 本の for_each)。
# 作成有無 (psql 連携時のみ等) は呼び出し側が map を絞って制御する。
resource "azurerm_data_factory_custom_dataset" "this" {
  for_each = var.datasets

  name            = each.value.name
  data_factory_id = azurerm_data_factory.this.id
  type            = each.value.type

  linked_service {
    name = local.linked_service_names[each.value.linked_service_key]
  }

  type_properties_json = each.value.type_properties_json
}

# Pipeline (name / parameters / activities_json をデータ駆動で for_each)。
# 作成有無は呼び出し側が pipelines map を絞って制御する。
resource "azurerm_data_factory_pipeline" "this" {
  for_each = var.pipelines

  name            = each.value.name
  data_factory_id = azurerm_data_factory.this.id
  parameters      = each.value.parameters
  activities_json = each.value.activities_json
  concurrency     = each.value.concurrency

  depends_on = [
    azurerm_data_factory_custom_dataset.this,
  ]
}

# Storage Blob Event Trigger (input/ への CSV 作成イベントで起動)
resource "azurerm_data_factory_trigger_blob_event" "this" {
  for_each = var.triggers

  name                  = each.value.name
  data_factory_id       = azurerm_data_factory.this.id
  storage_account_id    = each.value.storage_account_id
  events                = each.value.events
  blob_path_begins_with = each.value.blob_path_begins_with
  blob_path_ends_with   = each.value.blob_path_ends_with
  activated             = each.value.activated
  ignore_empty_blobs    = each.value.ignore_empty_blobs

  pipeline {
    name       = azurerm_data_factory_pipeline.this[each.value.pipeline_key].name
    parameters = each.value.pipeline_parameters
  }
}
