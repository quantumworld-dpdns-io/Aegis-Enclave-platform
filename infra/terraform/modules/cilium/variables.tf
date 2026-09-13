variable "cluster_name" {
  description = "Kind 叢集名稱。用來組出控制平面 DNS（<name>-control-plane），讓 Cilium 在 CoreDNS 還沒起來時也能打到 API Server。"
  type        = string
}

variable "cilium_version" {
  description = "Cilium Helm chart 版本。契約固定 1.20.1。"
  type        = string
}

variable "cilium_repository" {
  description = "Cilium Helm repository。預設官方 HTTP repo；可改 OCI（oci://quay.io/cilium/charts）。"
  type        = string
}

variable "enable_kube_proxy_replacement" {
  description = "是否啟用 kube-proxy replacement。macOS / Docker Desktop 請保持 false。"
  type        = bool
}

variable "enable_hubble" {
  description = "是否啟用 Hubble Relay / UI / metrics。"
  type        = bool
}

variable "enable_service_monitors" {
  description = "是否建立 Cilium/Hubble ServiceMonitor。必須在 prometheus-operator CRD 已安裝時才可為 true。"
  type        = bool
}

variable "prometheus_crds_ready" {
  description = "來自 observability 模組的 CRD 就緒訊號。只為了建立 implicit dependency，值本身不使用。"
  type        = string
}
