# ============================================================================
# 検証対象: AI Foundry の Storage 接続 (connection)
#
# AI Foundry (Hub ベース = Azure ML workspace) の接続は、authType が
# SAS / AccountKey / ApiKey のとき「シークレット本体を Hub の Key Vault に
# シークレットとして保存し、接続リソース自体にはその参照だけを持つ」構造になる。
# したがって Key Vault の閉域化は、この接続の解決経路 (RP -> Key Vault) に
# 直接効いてくる。
#
# 対照群として、シークレットを持たない AAD (Entra ID) 接続も 1 本作る。
# こちらは Key Vault を経由しないため、閉域化の影響を切り分けられる。
#
# AzureRM プロバイダは workspaces/connections に未対応のため azapi を使う。
# ============================================================================

# SAS の start / expiry を固定する。timestamp() を直接使うと plan のたびに
# 差分が出て接続が作り直されてしまうため。
resource "time_static" "sas" {}

data "azurerm_storage_account_sas" "data" {
  connection_string = module.storage_data.primary_connection_string
  https_only        = true
  signed_version    = "2022-11-02"

  resource_types {
    service   = true
    container = true
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  start  = time_static.sas.rfc3339
  expiry = timeadd(time_static.sas.rfc3339, "4320h") # 180 日

  permissions {
    read    = true
    write   = true
    delete  = false
    list    = true
    add     = true
    create  = true
    update  = false
    process = false
    tag     = false
    filter  = false
  }
}

locals {
  # AzureBlob 接続の向き先 (コンテナ URL)
  blob_connection_target = "${module.storage_data.primary_blob_endpoint}${local.sas_container_name}"

  blob_connection_metadata = {
    ApiType       = "Azure"
    ResourceId    = module.storage_data.storage_account_id
    accountName   = module.storage_data.storage_account_name
    containerName = local.sas_container_name
  }
}

# ---- Hub 直下の SAS 接続 ----------------------------------------------------
# isSharedToAll = true にすると配下の Project からも参照できる。
resource "azapi_resource" "hub_blob_sas" {
  type      = "Microsoft.MachineLearningServices/workspaces/connections@2024-10-01"
  name      = local.connections.hub_sas.name
  parent_id = module.ai_foundry.ai_foundry_id

  body = {
    properties = {
      category      = "AzureBlob"
      target        = local.blob_connection_target
      authType      = "SAS"
      isSharedToAll = true
      metadata      = local.blob_connection_metadata
    }
  }

  # SAS 本体は state に平文で置かないよう sensitive_body に分離する。
  sensitive_body = {
    properties = {
      credentials = {
        sas = data.azurerm_storage_account_sas.data.sas
      }
    }
  }

  # sensitive_body は API から読み戻せないため、値の変化はこのバージョンで検知する。
  sensitive_body_version = {
    "properties.credentials.sas" = sha256(data.azurerm_storage_account_sas.data.sas)
  }

  schema_validation_enabled = false
  response_export_values    = ["properties.category", "properties.authType", "properties.target"]
}

# ---- Project 直下の SAS 接続 ------------------------------------------------
# Project スコープの接続でもシークレットの保存先は Hub の Key Vault。
resource "azapi_resource" "project_blob_sas" {
  type      = "Microsoft.MachineLearningServices/workspaces/connections@2024-10-01"
  name      = local.connections.project_sas.name
  parent_id = module.ai_foundry.ai_foundry_project_id

  body = {
    properties = {
      category = "AzureBlob"
      target   = local.blob_connection_target
      authType = "SAS"
      metadata = local.blob_connection_metadata
    }
  }

  sensitive_body = {
    properties = {
      credentials = {
        sas = data.azurerm_storage_account_sas.data.sas
      }
    }
  }

  sensitive_body_version = {
    "properties.credentials.sas" = sha256(data.azurerm_storage_account_sas.data.sas)
  }

  schema_validation_enabled = false
  response_export_values    = ["properties.category", "properties.authType", "properties.target"]
}

# ---- 対照群: シークレットを持たない AAD 接続 --------------------------------
resource "azapi_resource" "project_blob_aad" {
  type      = "Microsoft.MachineLearningServices/workspaces/connections@2024-10-01"
  name      = local.connections.project_aad.name
  parent_id = module.ai_foundry.ai_foundry_project_id

  body = {
    properties = {
      category = "AzureBlob"
      target   = local.blob_connection_target
      authType = "AAD"
      metadata = local.blob_connection_metadata
    }
  }

  schema_validation_enabled = false
  response_export_values    = ["properties.category", "properties.authType", "properties.target"]
}
