output "crds_ready" {
  description = "CRD Helm release id。Cilium 模組用它建立「只等 CRD、不等 stack」的依賴。關閉時為 disabled。"
  value       = var.enabled ? helm_release.prometheus_operator_crds[0].id : "disabled"
}

output "namespace" {
  description = "可觀測性命名空間。未安裝時為 null。"
  value       = var.enabled ? kubernetes_namespace_v1.observability[0].metadata[0].name : null
}

output "grafana_service" {
  description = "Grafana Service 名稱。Makefile make grafana 依此 port-forward。"
  value       = var.enabled ? "${helm_release.kube_prometheus_stack[0].name}-grafana" : null
}

output "prometheus_url" {
  description = "本機 Prometheus URL。未暴露 NodePort 或未安裝時為 null。"
  value = var.enabled && var.expose_prometheus_nodeport ? (
    "http://127.0.0.1:${var.prometheus_node_port}"
  ) : null
}
