# Terraform 與 provider 版本鎖定。
#
# 為什麼要 pin：本專案要在五場駭客松的評審機器上「一鍵重現」，
# provider 若隨意飄版（尤其 helm provider 2.x → 3.x 的 set 語法變更）會直接讓 make up 失敗。
# 因此一律鎖大版本區間，只允許修補版更新。

terraform {
  # >= 1.9 才有 variable validation 可以跨變數引用（本專案 kubeconfig 路徑推導與驗證會用到）。
  required_version = ">= 1.9"

  required_providers {
    # tehcyx/kind：社群 provider，負責建立本機 Kind 叢集。
    # 注意：此 provider 內建的 kind 版本永遠落後上游，所以 node_image 必須由我們明確指定，
    # 不可依賴 provider 預設值（詳見 modules/kind-cluster/main.tf 的註解）。
    kind = {
      source  = "tehcyx/kind"
      version = ">= 0.9.0, < 1.0.0"
    }

    # helm provider 3.x 的 provider 設定改成 kubernetes = { ... } 屬性語法（不再是 block），
    # 且 set 由 block 變成物件清單。本專案的程式碼是照 3.x 寫的，故不可退回 2.x。
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0, < 4.0.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.35.0, < 3.0.0"
    }
  }
}
