# ============================================================================
# data_factory モジュール 入力変数
# - 各リソースは呼び出し元 locals (data_factories.main.*) の object マップで
#   for_each 拡張できる。エントリを足せばリソースが増える。
# ============================================================================
variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "integration_runtime_core_count" {
  type    = number
  default = 8
}

# Pipeline 一式 (name / parameters / activities_json をデータ駆動で for_each)。
# 「psql 連携時のみ作る」等の取捨選択は呼び出し側で map を絞って制御する
# (モジュールは業務ルールを持たない)。activities_json は SQL 差し込み済みの JSON 文字列。
variable "pipelines" {
  type = map(object({
    name            = string
    parameters      = optional(map(string), {})
    activities_json = string
    concurrency     = optional(number) # 同時実行数の上限 (1 で直列化)。未指定は ADF 既定。
  }))
  default = {}
}

# ---- 以下は data_factories.main.* の object で for_each 拡張する ----------

# ADF の SystemAssigned MI に付与するロール (principal は ADF 自身)
variable "role_assignments" {
  type = map(object({
    scope                = string
    role_definition_name = string
  }))
  default = {}

  validation {
    # 高権限ロールの誤付与を防ぐ軽量ガード (汎用性は維持し、危険ロールのみ拒否)。
    # 最小権限のデータ平面ロール (例: Storage Blob Data Contributor) を使うこと。
    condition = alltrue([
      for ra in values(var.role_assignments) :
      !contains(["Owner", "Contributor", "User Access Administrator", "Role Based Access Control Administrator"], ra.role_definition_name)
    ])
    error_message = "role_assignments に高権限ロール (Owner / Contributor / User Access Administrator / Role Based Access Control Administrator) は指定不可。最小権限のデータ平面ロールを使うこと。"
  }
}

# Managed Private Endpoint (Storage / PostgreSQL など)
variable "managed_private_endpoints" {
  type = map(object({
    name               = string
    target_resource_id = string
    subresource_name   = string
  }))
  default = {}
}

# Linked Service (Blob / PostgreSQL を kind で判別し 1 つの map で扱う)。
#   - kind="blob": Azure Blob Storage (MSI 認証)。service_endpoint を使用。
#   - kind="psql": PostgreSQL (azapi で V2/MSI JSON 投入)。server/database/... を使用。
# module 側で kind により for_each を絞ってそれぞれのリソースを作成する。
variable "linked_services" {
  type = map(object({
    kind                = string
    name                = string
    service_endpoint    = optional(string)
    server              = optional(string)
    database            = optional(string)
    port                = optional(number, 5432)
    ssl_mode            = optional(number, 2)
    authentication_type = optional(string, "SystemAssignedManagedIdentity")
  }))
  default = {}
}

# Dataset (Blob/DelimitedText も PostgreSQL/Table も同じ変数で扱う)。
# 各エントリは { name, type, linked_service_key, type_properties_json } を持つ object。
#   - name                 : ADF Dataset 名 (他リソースと同様 locals 側で明示。リソースは each.value.name を使う)
#   - type                 : "DelimitedText" / "AzurePostgreSqlTable" 等
#   - linked_service_key   : blob_linked_services または psql_linked_services のキー
#   - type_properties_json : ADF Dataset の typeProperties を JSON 文字列で (そのまま投入)。
#                            呼び出し側で templatefile/file により生成する (pipeline と同じ string 方式)。
variable "datasets" {
  type = map(object({
    name                 = string
    type                 = string
    linked_service_key   = string
    type_properties_json = string
  }))
  default = {}
}

# Blob Event Trigger
variable "triggers" {
  type = map(object({
    name                  = string
    storage_account_id    = string
    blob_path_begins_with = string
    blob_path_ends_with   = string
    pipeline_key          = string # 起動対象パイプライン (pipelines のキー)
    events                = optional(list(string), ["Microsoft.Storage.BlobCreated"])
    activated             = optional(bool, true)
    ignore_empty_blobs    = optional(bool, true)
    pipeline_parameters   = optional(map(string), {})
  }))
  default = {}
}
