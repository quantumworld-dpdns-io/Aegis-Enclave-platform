# 根模組輸出。Makefile 主要靠 kubeconfig 檔案路徑，不讀這些 output；
# 保留給 terraform output / 評審查驗 / 其他模組文件對照。

output "cluster_name" {
  description = "Kind 叢集名稱。必須與 Makefile CLUSTER_NAME、docs/CONTRACT.md 一致。"
  value       = module.kind_cluster.cluster_name
}

output "kubeconfig_path" {
  description = "kubeconfig 檔案路徑。make deploy / make grafana 的 KUBECONFIG 指向這裡。"
  value       = module.kind_cluster.kubeconfig_path
}

output "cluster_endpoint" {
  description = "Kubernetes API Server 端點。"
  value       = module.kind_cluster.endpoint
}

output "observability_namespace" {
  description = "kube-prometheus-stack 所在命名空間。enable_observability=false 時為 null。"
  value       = module.observability.namespace
}

output "prometheus_url" {
  description = "本機 Prometheus 存取 URL（NodePort 對映）。未暴露 NodePort 或未安裝時為 null。"
  value       = module.observability.prometheus_url
}

output "grafana_service" {
  description = "Grafana Service 名稱，對齊 Makefile 的 kube-prometheus-stack-grafana。"
  value       = module.observability.grafana_service
}

output "cilium_version" {
  description = "實際安裝的 Cilium Helm chart 版本。"
  value       = module.cilium.chart_version
}

output "kube_proxy_replacement" {
  description = "是否啟用 Cilium kube-proxy replacement。macOS 上應保持 false。"
  value       = var.enable_kube_proxy_replacement
}
