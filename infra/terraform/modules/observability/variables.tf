variable "enabled" {
  description = "是否安裝 prometheus-operator CRD 與 kube-prometheus-stack。"
  type        = bool
}

variable "namespace" {
  description = "可觀測性命名空間。契約固定為 observability。不建立 aegis / attacker。"
  type        = string
  default     = "observability"
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack Helm chart 版本。"
  type        = string
}

variable "prometheus_operator_crds_version" {
  description = "prometheus-operator-crds Helm chart 版本。必須在 Cilium ServiceMonitor 之前就緒。"
  type        = string
}

variable "grafana_admin_password" {
  description = "Grafana admin 密碼。僅供本機 demo。"
  type        = string
  sensitive   = true
}

variable "expose_prometheus_nodeport" {
  description = "是否把 Prometheus Service 改成 NodePort。"
  type        = bool
}

variable "prometheus_node_port" {
  description = "Prometheus NodePort 號碼，須與 Kind extraPortMappings 一致。"
  type        = number
}

variable "prometheus_community_repository" {
  description = "prometheus-community Helm repository。"
  type        = string
  default     = "https://prometheus-community.github.io/helm-charts"
}
