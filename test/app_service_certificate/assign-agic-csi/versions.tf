terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.3"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    key_vault {
      # 【ハマりどころ】azurerm は destroy 時に KV オブジェクトを
      # soft-delete したうえで **purge(完全削除) まで実行する**のが既定。
      # ところが purge には KV の "Purge" 権限が必要で、cert/ 側の access policy は
      # Get/List/Create/Import/Update/Delete しか与えていないため 403 で destroy が失敗する:
      #
      #   Error: purging of Certificate "appgw-tls-cert-pem" ... StatusCode=403
      #     "does not have certificates purge permission on key vault 'kv-appgwcert-xxxx'"
      #
      # そもそもこの証明書は **cert/ が所有する KeyVault の中に作った import 済みコピー**であり、
      # assign-agic-csi の destroy で purge まで踏み込むべきではない
      # (soft-delete の保持期間 7 日で自動的に purge される)。
      # → purge を無効化し、論理削除に留める。
      purge_soft_deleted_certificates_on_destroy = false
    }
  }
}
