# Aegis-Enclave 模組 D：本機 Kind 叢集 + Cilium + kube-prometheus-stack。
#
# 本模組只負責「座艙」本身，不建立 aegis / attacker namespace —— 那是模組 E
#（infra/k8s/base）的所有權，平行開發時若兩邊都建，會互相覆蓋 PSA 標籤。
# observability namespace 則由本模組建立，因為 kube-prometheus-stack 必須先有它。
#
# 套用順序（靠 implicit dependency，不必人工 -target）：
#   1. Kind 叢集（disableDefaultCNI=true，節點此時 NotReady）
#   2. prometheus-operator-crds（讓 ServiceMonitor CRD 先存在）
#   3. Cilium（CNI 就緒後節點才會 Ready；可建立 Hubble/agent ServiceMonitor）
#   4. kube-prometheus-stack（略過 CRD，避免與步驟 2 衝突）
#
# 為什麼 CRD 要拆開、而且要在 Cilium 之前：
#   Cilium chart 在 hubble.metrics.serviceMonitor.enabled=true 時會建立 ServiceMonitor。
#   若當時還沒有該 CRD，Helm 會直接失敗。kube-prometheus-stack 本身含 CRD，
#   但它太重、安裝時間長，不適合擋在 Cilium 前面；所以先用只含 CRD 的薄 chart。

locals {
  # Makefile 的 KUBECONFIG_PATH 預設指向這裡。使用 abspath 以免從其他 cwd 呼叫 terraform 時寫到錯地方。
  kubeconfig_path = coalesce(var.kubeconfig_path, abspath("${path.module}/kubeconfig"))
}

# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

provider "kind" {}

# helm 3.x：kubernetes 是物件屬性，不是 block。憑證直接吃 kind_cluster 輸出（已是 PEM）。
provider "helm" {
  kubernetes = {
    host                   = module.kind_cluster.endpoint
    client_certificate     = module.kind_cluster.client_certificate
    client_key             = module.kind_cluster.client_key
    cluster_ca_certificate = module.kind_cluster.cluster_ca_certificate
  }
}

provider "kubernetes" {
  host                   = module.kind_cluster.endpoint
  client_certificate     = module.kind_cluster.client_certificate
  client_key             = module.kind_cluster.client_key
  cluster_ca_certificate = module.kind_cluster.cluster_ca_certificate
}

# ---------------------------------------------------------------------------
# 1. Kind 叢集
# ---------------------------------------------------------------------------

module "kind_cluster" {
  source = "./modules/kind-cluster"

  cluster_name               = var.cluster_name
  node_image                 = var.node_image
  worker_count               = var.worker_count
  pod_subnet                 = var.pod_subnet
  service_subnet             = var.service_subnet
  kubeconfig_path            = local.kubeconfig_path
  host_listen_address        = var.host_listen_address
  http_host_port             = var.http_host_port
  https_host_port            = var.https_host_port
  prometheus_host_port       = var.prometheus_host_port
  kube_proxy_replacement     = var.enable_kube_proxy_replacement
  expose_prometheus_nodeport = var.expose_prometheus_nodeport
}

# ---------------------------------------------------------------------------
# 2 + 4. 可觀測性（CRD 先、stack 後；Cilium 只等 CRD）
# ---------------------------------------------------------------------------

module "observability" {
  source = "./modules/observability"

  enabled                          = var.enable_observability
  kube_prometheus_stack_version    = var.kube_prometheus_stack_version
  prometheus_operator_crds_version = var.prometheus_operator_crds_version
  grafana_admin_password           = var.grafana_admin_password
  expose_prometheus_nodeport       = var.expose_prometheus_nodeport
  prometheus_node_port             = var.prometheus_host_port
}

# ---------------------------------------------------------------------------
# 3. Cilium CNI
# ---------------------------------------------------------------------------
# prometheus_crds_ready 只引用 CRD release 的 id，因此這裡不會等到整個
# kube-prometheus-stack 裝完 —— stack 與 Cilium 可以在 CRD 就緒後並行。

module "cilium" {
  source = "./modules/cilium"

  cluster_name                  = var.cluster_name
  cilium_version                = var.cilium_version
  cilium_repository             = var.cilium_repository
  enable_kube_proxy_replacement = var.enable_kube_proxy_replacement
  enable_hubble                 = var.enable_hubble
  enable_service_monitors       = var.enable_observability
  prometheus_crds_ready         = module.observability.crds_ready
}
