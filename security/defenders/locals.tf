# ============================================================================
# 環境設定値 (locals で集中管理)
# ============================================================================
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  location = var.location
  prefix   = "mdc"
  suffix   = random_string.suffix.result

  tags = {
    project = "security-defenders"
    env     = "sandbox"
  }

  resource_group_name = "rg-${local.prefix}-${local.suffix}"

  # ---- Defender プラン (Microsoft.Security/pricings) ------------------------
  # resource_type は pricings API の name。サブスクリプション単位で 1 つずつ。
  # Containers 以外は enable_subscription_level_plans = true のときだけ作る。
  subscription_plans = {
    StorageAccounts = {
      enabled = var.targets.storage && var.enable_subscription_level_plans
      subplan = "DefenderForStorageV2"
      extensions = {
        OnUploadMalwareScanning = { CapGBPerMonthPerStorageAccount = tostring(var.storage_malware_scanning_cap_gb) }
        SensitiveDataDiscovery  = null
      }
    }
    Containers = {
      enabled = var.targets.containers
      subplan = null
      extensions = {
        ContainerRegistriesVulnerabilityAssessments = null # レジストリイメージの脆弱性評価 (エージェントレス)
        AgentlessDiscoveryForKubernetes             = null # K8s API のエージェントレス検出
        ContainerSensor                             = null # ノードの Defender センサー (実行時の脅威検出)
      }
    }
    OpenSourceRelationalDatabases = {
      enabled    = var.targets.postgresql && var.enable_subscription_level_plans
      subplan    = null
      extensions = {}
    }
    CosmosDbs = {
      enabled    = var.targets.cosmosdb && var.enable_subscription_level_plans
      subplan    = null
      extensions = {}
    }
  }

  # ---- Storage --------------------------------------------------------------
  storage = {
    name           = "st${local.prefix}${local.suffix}"
    container_name = "upload"
  }

  # ---- Containers (AKS + ACR + LAW) -----------------------------------------
  # Defender for Containers は vCore 単位の課金なので 2 vCPU の最小ノード 1 台にする。
  aks = {
    name            = "aks-${local.prefix}-${local.suffix}"
    vm_size         = "Standard_B2s"
    node_count      = 1
    os_disk_size_gb = 32 # 既定の 128 GB (P10) だとディスクがノードより高くなる
  }
  acr = {
    name = "acr${local.prefix}${local.suffix}"
    sku  = "Basic"
  }
  law = {
    name = "law-${local.prefix}-${local.suffix}"
    sku  = "PerGB2018"
    # サンドボックスでの取り込み事故を防ぐための日次上限 (GB)
    daily_quota_gb = 0.1
  }

  # ---- PostgreSQL フレキシブルサーバー ----------------------------------------
  # Defender for open-source relational databases は全価格レベル (Burstable 含む) が対象なので最小 SKU。
  postgresql = {
    name       = "psql-${local.prefix}-${local.suffix}"
    sku_name   = "B_Standard_B1ms"
    version    = "16"
    storage_mb = 32768
    # advancedThreatProtectionSettings の API バージョン (azure-rest-api-specs の stable)
    atp_api_version = "2025-08-01"
  }

  # ---- Cosmos DB (NoSQL) ----------------------------------------------------
  # サーバーレスにして RU のプロビジョニング費用を発生させない。
  cosmosdb = {
    name           = "cosmos-${local.prefix}-${local.suffix}"
    database_name  = "sample"
    container_name = "items"
    # 組み込みロール "Cosmos DB Built-in Data Contributor"
    data_contributor_role_id = "00000000-0000-0000-0000-000000000002"
  }
}
