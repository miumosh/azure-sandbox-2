# ============================================================================
# Hub env 設定値 (object 型の locals で集中管理)
# - 機微情報 / cross-sub 参照のみ variables.tf (tfvars)。それ以外はここで定義する。
# - 各リソースは local.<plural>.main.<attr> 形式で参照する。
# ============================================================================
locals {
  location = "japaneast"
  prefix   = "ci00"

  tags = {
    project = "storage-adf-psql-function-aks-relation"
    env     = "test"
    tier    = "hub"
  }

  resource_group_name = "${local.prefix}-hub-rg"
  psql_database_name  = "appdb" # Spoke の DB 名と一致させる (ADF 接続先)

  # cross-subscription 連携の段階制御 (apply 順序は README 参照)
  spoke_peering_enabled = var.spoke_vnet_id != ""

  # ---- ネットワーク -------------------------------------------------------
  vnet = {
    name          = "${local.prefix}-hub-vnet"
    address_space = ["10.39.0.0/16"]
  }

  subnets = {
    jumpbox    = { name = "snet-jumpbox", address_prefixes = ["10.39.2.0/24"] }
    pe_storage = { name = "snet-pe-storage", address_prefixes = ["10.39.10.0/24"] }
    pe_acr     = { name = "snet-pe-acr", address_prefixes = ["10.39.11.0/24"] }
  }

  # NSG (L4 制御)。踏み台 VM は public IP を持つため、SSH を許可元 IP のみに絞る。
  network_security_groups = {
    jumpbox = {
      name       = "snet-jumpbox-nsg"
      subnet_key = "jumpbox"
      rules = [
        {
          name                       = "Allow-Operator-SSH-22"
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "22"
          source_address_prefix      = var.allowed_upload_ip
          destination_address_prefix = local.subnets.jumpbox.address_prefixes[0]
        },
      ]
    }
  }

  # Private DNS Zone (virtual_network_id = "self" は本 env の VNet を指す)
  # blob ゾーンは持たない: hub storage は public(IP制限)/ADF は Managed PE で接続し、
  # func storage(Spoke) の blob ゾーンは Spoke 所有。踏み台は Spoke の blob ゾーン経由で解決する。
  dns_zones = {
    acr = {
      name = "privatelink.azurecr.io"
      # AKS(Spoke) が ACR PE を解決できるよう、設定済みなら Spoke VNet にもリンク
      links = merge(
        { hub = { name = "acr-hub-link", virtual_network_id = "self" } },
        local.spoke_peering_enabled ? { spoke = { name = "acr-spoke-link", virtual_network_id = var.spoke_vnet_id } } : {}
      )
    }
  }

  peerings = local.spoke_peering_enabled ? {
    hub_to_spoke = { name = "hub-to-spoke", remote_virtual_network_id = var.spoke_vnet_id }
  } : {}

  # ---- サービス -----------------------------------------------------------
  storage_accounts = {
    main = {
      name              = "ci00storageaccount"
      upload_container  = "ciupload39container"
      archive_container = "ciarchive39container"
    }
  }

  container_registries = {
    main = { name = "${local.prefix}acr" }
  }

  jumpboxes = {
    main = {
      name           = "${local.prefix}-jumpbox"
      vm_size        = "Standard_B1s"
      admin_username = "azureuser"
    }
  }

  adf_main_ready         = var.psql_server_id != ""
  adf_main_template_path = "${path.module}/files/adf_pipeline/customer_info_registration"

  data_factories = {
    # ADF (main): 接続先 psql が利用可能なときのみ作成。無効時は null (main.tf の for_each が除外)。
    # 将来 ADF を増やす場合はエントリごとに別フラグで制御できる。
    main = local.adf_main_ready ? {
      name = "${local.prefix}-adf"

      # ADF MI へ付与するロール (principal は ADF 自身。エントリを足せば増える)
      roles = {
        storage_blob_contributor = {
          scope                = module.storage.id
          role_definition_name = "Storage Blob Data Contributor"
        }
        # psql は DB サーバ内で権限付与を行う
      }

      # Managed Private Endpoint (Storage Blob / PostgreSQL)
      managed_private_endpoints = {
        blob = { name = "mpe-storage-blob", target_resource_id = module.storage.id, subresource_name = "blob" }
        psql = { name = "mpe-psql", target_resource_id = var.psql_server_id, subresource_name = "postgresqlServer" }
      }

      # Linked Service: 単一 map (kind で blob/psql を判別)。
      # キーは論理名 (blob/psql)、name は ADF 上の LS 名 (pipeline.json が ls_psql を参照)。
      linked_services = {
        blob = { kind = "blob", name = "ls_blob", service_endpoint = "https://${module.storage.name}.blob.core.windows.net" }
        psql = { kind = "psql", name = "ls_psql", server = var.psql_fqdn, database = local.psql_database_name }
      }

      # Trigger。pipeline_key で起動対象パイプラインを指す。
      triggers = {
        trg_csv_uploaded = {
          name                  = "trg_csv_uploaded"
          storage_account_id    = module.storage.id
          blob_path_begins_with = "/${local.storage_accounts.main.upload_container}/blobs/input/"
          blob_path_ends_with   = ".csv"
          pipeline_key          = "pl_csv_ingest"
          activated             = var.ingestion_trigger_activated # テスト時 false / 運用時 true で切替
          pipeline_parameters   = { triggeredFileName = "@triggerBody().fileName" }
        }
      }

      pipelines = {
        pl_csv_ingest = {
          name        = "pl_csv_ingest"
          concurrency = 1 # 同時実行を直列化。連続アップロードでの landing TRUNCATE / staging swap 競合を防止。
          # 検証 SQL は pipeline parameter として渡し、Script activity が
          # "text": "@{pipeline().parameters.validation_sql}" で参照する。
          # triggeredFileName はトリガーが override、validation_sql は default を使用。
          parameters = {
            triggeredFileName = ""
            validation_sql    = file("${local.adf_main_template_path}/queries/validation.sql")
          }
          # pipeline.json には ${...} 注入が無いので file() でそのまま読む (@{} は ADF 式で TF 非干渉)。
          activities_json = file("${local.adf_main_template_path}/pipeline.json")
        }
      }

      # Dataset: name/type/linked_service_key は locals で管理し、type_properties_json のみ
      # files/.../datasets/<key>.json から文字列で読む (pipeline と同じ templatefile→string 方式)。
      # Blob 系は container 名を templatefile 注入、psql 系は静的。
      datasets = {
        # Using Copy Activity: InputCSV
        src_csv = {
          name               = "ds_src_csv"
          type               = "DelimitedText"
          linked_service_key = "blob"
          type_properties_json = templatefile("${local.adf_main_template_path}/datasets/ds_src_csv.json", {
            upload_container = local.storage_accounts.main.upload_container
          })
        }
        # Using Script Activity: ValidateData
        customer_info_landing = {
          name                 = "ds_customer_info_landing"
          type                 = "AzurePostgreSqlTable"
          linked_service_key   = "psql"
          type_properties_json = templatefile("${local.adf_main_template_path}/datasets/ds_customer_info_landing.json", {})
        }
        customer_info_error = {
          name                 = "ds_customer_info_error"
          type                 = "AzurePostgreSqlTable"
          linked_service_key   = "psql"
          type_properties_json = templatefile("${local.adf_main_template_path}/datasets/ds_customer_info_error.json", {})
        }
        customer_info_production = {
          name                 = "ds_customer_info_production"
          type                 = "AzurePostgreSqlTable"
          linked_service_key   = "psql"
          type_properties_json = templatefile("${local.adf_main_template_path}/datasets/ds_customer_info_production.json", {})
        }
        # Using Copy Activity: ArchiveSuccess
        archive_success_csv = {
          name               = "ds_archive_success_csv"
          type               = "DelimitedText"
          linked_service_key = "blob"
          type_properties_json = templatefile("${local.adf_main_template_path}/datasets/ds_archive_success_csv.json", {
            archive_container = local.storage_accounts.main.archive_container
          })
        }
        # Using Copy Activity: ArchiveError
        archive_error_csv = {
          name               = "ds_archive_error_csv"
          type               = "DelimitedText"
          linked_service_key = "blob"
          type_properties_json = templatefile("${local.adf_main_template_path}/datasets/ds_archive_error_csv.json", {
            archive_container = local.storage_accounts.main.archive_container
          })
        }
      }
    } : null
  }
}
