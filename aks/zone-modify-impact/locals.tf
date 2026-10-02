# ============================================================================
# 環境設定値 (locals で集中管理)
# ============================================================================
locals {
  location = var.location
  prefix   = "akszone"

  tags = {
    project = "aks-zone-modify-impact"
    env     = "sandbox"
  }

  resource_group_name = "${local.prefix}-rg"
  cluster_name        = "aks-${local.prefix}"

  # 別環境に合わせて固定する。未指定だと作成時点の既定バージョンになり、再現性が落ちる。
  kubernetes_version = "1.35"

  # ---- ノードプール ---------------------------------------------------------
  # VM サイズ選定の条件 (japaneast で実測した SKU 情報より):
  #   - ゾーン 1/2/3 すべてで提供されていること
  #     (D*s_v6 / D*as_v6 系は japaneast では zones=[1,2] のみ。3 ゾーン指定は失敗する)
  #   - PremiumIO 対応 (Premium_ZRS ディスクを付けるため)
  #   - サブスクリプションの vCPU クォータ内に、rotation 中のピークも含めて収まること
  #     (リージョン合計 10 vCPU / standardDSv3Family 10 vCPU)
  #
  # rotation 中は「元のプール + 同じノード数の一時プール」が同時に存在するため、
  # ピーク vCPU = 平常時 + 回転中プールのノード数 x 2。
  #   平常時   : system 1 + user 2 = 3 ノード = 6 vCPU
  #   ピーク   : user 回転中 3 + 2 = 5 ノード = 10 vCPU (上限ちょうど)
  system_pool = {
    name                        = "system"
    temporary_name_for_rotation = "systemtmp"
    vm_size                     = "Standard_D2s_v3"
    node_count                  = 1
  }

  user_pool = {
    name                        = "user"
    temporary_name_for_rotation = "usertmp"
    vm_size                     = "Standard_D2s_v3"
    node_count                  = 2
  }
}
