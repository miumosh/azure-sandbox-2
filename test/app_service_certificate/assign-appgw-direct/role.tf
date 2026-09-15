# ============================================================
# Azure RBAC Role Assignments
# ref: memo/ai_order.md §7-2
# ============================================================

# 1. AGIC UAI: Reader @ Resource Group
resource "azurerm_role_assignment" "agic_reader_rg" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# 2. AGIC UAI: Contributor @ AppGW
resource "azurerm_role_assignment" "agic_contributor_appgw" {
  scope                = azurerm_application_gateway.appgw.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# 3. AGIC UAI: Network Contributor @ appgw-subnet (Route Table join/action)
resource "azurerm_role_assignment" "agic_netcontrib_appgw_subnet" {
  scope                = azurerm_subnet.appgw.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# 4. AGIC UAI: Network Contributor @ MC_ RG (Route Table read — 見落としやすい)
resource "azurerm_role_assignment" "agic_netcontrib_mc_rg" {
  scope                = azurerm_kubernetes_cluster.aks.node_resource_group_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}

# 5. AKS Control Plane MI: Network Contributor @ aks-subnet
resource "azurerm_role_assignment" "aks_cp_netcontrib_aks_subnet" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}

# ============================================================
# 6. AGIC UAI: Managed Identity Operator @ AppGW の KV 用 UAI
#
# 【方式A 固有のハマりどころ】
# 方式A では AppGW 自身に UserAssigned Identity (certdirect-appgw-kv-identity) を
# 紐付けて KeyVault を読ませる。この状態で AGIC が AppGW を更新 (PUT) すると、
# リクエストボディに その UAI への参照 (identity ブロック) が含まれる。
#
# ARM は「UAI を参照するリソースを書く側」に、その UAI に対する
#   Microsoft.ManagedIdentity/userAssignedIdentities/assign/action
# を要求する。AGIC は AppGW の Contributor ではあるが、UAI 側の権限が無いため
# 以下の 403 で AppGW を一切更新できず、Ingress が反映されない:
#
#   Code="LinkedAuthorizationFailed"
#   "...has permission to perform action 'Microsoft.Network/applicationGateways/write'
#    ...; however, it does not have permission to perform action(s)
#    'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action' on the linked
#    scope(s) '.../userAssignedIdentities/certdirect-appgw-kv-identity'"
#
# Managed Identity Operator ロールが assign/action を含むのでこれを付与する。
# 方式B (assign-agic-csi) は AppGW に UAI を付けないため、この権限は不要。
# ============================================================
resource "azurerm_role_assignment" "agic_mi_operator_appgw_kv" {
  scope                = azurerm_user_assigned_identity.appgw_kv.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.agic.principal_id
}
