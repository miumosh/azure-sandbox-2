# ============================================================================
# Spoke env 設定値 (object 型の locals で集中管理)
# - 機微情報 / cross-sub 参照のみ variables.tf (tfvars)。それ以外はここで定義する。
# - 各リソースは local.<plural>.main.<attr> 形式で参照する。
# ============================================================================
locals {
  location = "japaneast"
  prefix   = "ci00"

  tags = {
    project = "storage-adf-psql-function-aks-relation"
    env     = "test"
    tier    = "spoke"
  }

  resource_group_name = "${local.prefix}-spoke-rg"
  log_analytics_name  = "${local.prefix}-log"
  psql_database_name  = "appdb"
  psql_admin_login    = "psqladmin"

  # cross-subscription 連携の段階制御 (Hub apply 後に hub_vnet_id を設定)
  hub_peering_enabled = var.hub_vnet_id != ""

  # ---- ネットワーク -------------------------------------------------------
  vnet = {
    name          = "${local.prefix}-spoke-vnet"
    address_space = ["10.40.0.0/16"]
  }

  subnets = {
    aks     = { name = "snet-aks", address_prefixes = ["10.40.1.0/24"] }
    pe_psql = { name = "snet-pe-psql", address_prefixes = ["10.40.10.0/24"] }
    # NSG を PE の NIC に効かせるため Enabled (元 network.tf の設定を踏襲)
    pe_func = { name = "snet-pe-func", address_prefixes = ["10.40.11.0/24"], private_endpoint_network_policies = "Enabled" }
    # Function 用 Storage の PE (blob/queue/table) 配置先。NSG を効かせるため Enabled。
    pe_stfunc = { name = "snet-pe-stfunc", address_prefixes = ["10.40.12.0/24"], private_endpoint_network_policies = "Enabled" }
    func_integration = {
      name             = "snet-func-int"
      address_prefixes = ["10.40.20.0/24"]
      delegation = {
        name         = "serverFarm-delegation"
        service_name = "Microsoft.Web/serverFarms"
        actions      = ["Microsoft.Network/virtualNetworks/subnets/action"]
      }
    }
  }

  # Private DNS Zone (virtual_network_id = "self" は本 env の VNet を指す)
  dns_zones = {
    psql = {
      name = "privatelink.postgres.database.azure.com"
      # 踏み台 VM から解決できるよう、設定済みなら Hub VNet にもリンク
      links = merge(
        { spoke = { name = "psql-spoke-link", virtual_network_id = "self" } },
        local.hub_peering_enabled ? { hub = { name = "psql-hub-link", virtual_network_id = var.hub_vnet_id } } : {}
      )
    }
    func = {
      name = "privatelink.azurewebsites.net"
      links = {
        spoke = { name = "func-spoke-link", virtual_network_id = "self" }
      }
    }
    # Function 用 Storage の PE 用ゾーン。
    # blob は踏み台 VM(Hub)からも解決させるため Hub にもリンク。queue/table は Function(Spoke)専用。
    blob = {
      name = "privatelink.blob.core.windows.net"
      links = merge(
        { spoke = { name = "blob-spoke-link", virtual_network_id = "self" } },
        local.hub_peering_enabled ? { hub = { name = "blob-hub-link", virtual_network_id = var.hub_vnet_id } } : {}
      )
    }
    queue = {
      name = "privatelink.queue.core.windows.net"
      links = {
        spoke = { name = "queue-spoke-link", virtual_network_id = "self" }
      }
    }
    table = {
      name = "privatelink.table.core.windows.net"
      links = {
        spoke = { name = "table-spoke-link", virtual_network_id = "self" }
      }
    }
  }

  peerings = local.hub_peering_enabled ? {
    spoke_to_hub = { name = "spoke-to-hub", remote_virtual_network_id = var.hub_vnet_id }
  } : {}

  # NSG (L4 制御)。決定的な制御点は snet-pe-func の inbound。
  network_security_groups = {
    pe_func = {
      name       = "snet-pe-func-nsg"
      subnet_key = "pe_func"
      rules = [
        {
          name                       = "Allow-AKS-to-FuncPE-443"
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = local.subnets.aks.address_prefixes[0]
          destination_address_prefix = local.subnets.pe_func.address_prefixes[0]
        },
        {
          name                       = "Allow-AzureLoadBalancer"
          priority                   = 200
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "*"
          source_port_range          = "*"
          destination_port_range     = "*"
          source_address_prefix      = "AzureLoadBalancer"
          destination_address_prefix = "*"
        },
        {
          name                       = "Deny-Other-Vnet-Inbound"
          priority                   = 300
          direction                  = "Inbound"
          access                     = "Deny"
          protocol                   = "*"
          source_port_range          = "*"
          destination_port_range     = "*"
          source_address_prefix      = "VirtualNetwork"
          destination_address_prefix = "*"
        },
      ]
    }
    # Function 用 Storage の PE サブネット。踏み台 VM(Hub) と Function 統合サブネット(Spoke) のみ 443 許可。
    pe_stfunc = {
      name       = "snet-pe-stfunc-nsg"
      subnet_key = "pe_stfunc"
      rules = [
        {
          name                       = "Allow-Jumpbox-to-StPE-443"
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = "10.39.2.0/24" # Hub snet-jumpbox
          destination_address_prefix = local.subnets.pe_stfunc.address_prefixes[0]
        },
        {
          name                       = "Allow-FuncInt-to-StPE-443"
          priority                   = 110
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = local.subnets.func_integration.address_prefixes[0]
          destination_address_prefix = local.subnets.pe_stfunc.address_prefixes[0]
        },
        {
          name                       = "Deny-Other-Vnet-Inbound"
          priority                   = 300
          direction                  = "Inbound"
          access                     = "Deny"
          protocol                   = "*"
          source_port_range          = "*"
          destination_port_range     = "*"
          source_address_prefix      = "VirtualNetwork"
          destination_address_prefix = "*"
        },
      ]
    }
    aks = {
      name       = "snet-aks-nsg"
      subnet_key = "aks"
      rules = [
        {
          name                       = "Allow-LB-Inbound-HTTP"
          priority                   = 100
          direction                  = "Inbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "80"
          source_address_prefix      = "Internet"
          destination_address_prefix = "*"
        },
        {
          name                       = "Allow-AKS-to-FuncPE-443"
          priority                   = 100
          direction                  = "Outbound"
          access                     = "Allow"
          protocol                   = "Tcp"
          source_port_range          = "*"
          destination_port_range     = "443"
          source_address_prefix      = local.subnets.aks.address_prefixes[0]
          destination_address_prefix = local.subnets.pe_func.address_prefixes[0]
        },
      ]
    }
  }

  # ---- サービス -----------------------------------------------------------
  postgresql_servers = {
    main = { name = "${local.prefix}-psql" }
  }

  aks_clusters = {
    main = {
      name       = "${local.prefix}-aks"
      dns_prefix = "${local.prefix}-aks"
      node_size  = "Standard_D2s_v3"
      node_count = 1
    }
  }

  function_apps = {
    main = {
      name                  = "${local.prefix}-func"
      plan_name             = "${local.prefix}-func-plan"
      storage_name          = "${local.prefix}funcst${random_string.func_storage.result}" # Storage 名はグローバル一意のため乱数付与
      deployments_container = "deployments"                                               # run-from-package zip 置き場

      # Function App の app_settings (FUNCTIONS_WORKER_RUNTIME / PSQL_* / WEBSITE_RUN_FROM_PACKAGE)。
      # PSQL_USER は Function MI 表示名 (= name)。password はコード側で AAD トークンを取得して使う。
      # WEBSITE_RUN_FROM_PACKAGE は SAS なし Blob URL (ID ベース。MI が Storage Blob Data Owner で読む)。
      #   var.func_package_name を更新して apply するたび値が変わり Function が自動再起動する。
      # ※ object 内では sibling 属性 (name/storage_name 等) を参照できないため、ここでは literal で再掲する。
      app_settings = merge(
        {
          FUNCTIONS_WORKER_RUNTIME = "python"
          AzureWebJobsFeatureFlags = "EnableWorkerIndexing"
          PSQL_HOST                = module.postgresql.fqdn
          PSQL_DATABASE            = local.psql_database_name
          PSQL_USER                = "${local.prefix}-func"
          PSQL_PORT                = "5432"
          PSQL_SSLMODE             = "require"
        },
        var.func_package_name != "" ? {
          WEBSITE_RUN_FROM_PACKAGE = "https://${local.prefix}funcst${random_string.func_storage.result}.blob.core.windows.net/deployments/${var.func_package_name}"
        } : {}
      )
    }
  }
}
