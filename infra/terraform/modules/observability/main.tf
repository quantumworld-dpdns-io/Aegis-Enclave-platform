# kube-prometheus-stack + 先行安裝的 prometheus-operator CRD。
#
# 本模組只建立 observability namespace，刻意不建立 aegis / attacker ——
# 那兩個信任邊界由模組 E（infra/k8s/base）擁有，含 PSA 標籤。
#
# PSA 必須用 privileged：node-exporter 需要 hostPath / hostNetwork，
# kube-state-metrics 與 operator 也不符合 restricted。這與 aegis 的 restricted 是刻意對照。
#
# selectorNilUsesHelmValues=false：
#   Helm chart 預設會讓 Prometheus 只抓帶有 release=<helm release> 標籤的
#   ServiceMonitor / PodMonitor / PrometheusRule。Cilium 與模組 F 的資源都沒有這個標籤，
#   關掉之後空 selector 代表「全部監聽」，微分段 drop 指標與 aegis_* 告警才會進 Prometheus。

resource "kubernetes_namespace_v1" "observability" {
  count = var.enabled ? 1 : 0

  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/part-of"                  = "aegis-enclave"
      "app.kubernetes.io/component"                = "observability"
      "pod-security.kubernetes.io/enforce"         = "privileged"
      "pod-security.kubernetes.io/enforce-version" = "v1.31"
      "pod-security.kubernetes.io/audit"           = "privileged"
      "pod-security.kubernetes.io/audit-version"   = "v1.31"
      "pod-security.kubernetes.io/warn"            = "privileged"
      "pod-security.kubernetes.io/warn-version"    = "v1.31"
    }
  }
}

# 薄 chart，只裝 CRD。Cilium 的 ServiceMonitor 依賴它先存在。
resource "helm_release" "prometheus_operator_crds" {
  count = var.enabled ? 1 : 0

  name       = "prometheus-operator-crds"
  repository = var.prometheus_community_repository
  chart      = "prometheus-operator-crds"
  version    = var.prometheus_operator_crds_version
  namespace  = kubernetes_namespace_v1.observability[0].metadata[0].name

  wait             = true
  atomic           = true
  timeout          = 180
  cleanup_on_fail  = true
  create_namespace = false
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.enabled ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = var.prometheus_community_repository
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  namespace  = kubernetes_namespace_v1.observability[0].metadata[0].name

  wait             = true
  atomic           = true
  timeout          = 900
  cleanup_on_fail  = true
  create_namespace = false

  # 等 CRD 進 API Server 再裝 stack，否則 Prometheus 自帶的 ServiceMonitor 也會失敗。
  depends_on = [helm_release.prometheus_operator_crds]

  values = [
    yamlencode({
      crds = {
        # CRD 已由上面的薄 chart 安裝，避免兩套 chart 搶同一個 CRD 物件。
        enabled = false
      }

      prometheus = {
        service = var.expose_prometheus_nodeport ? {
          type     = "NodePort"
          nodePort = var.prometheus_node_port
          } : {
          type = "ClusterIP"
        }
        prometheusSpec = {
          ruleSelectorNilUsesHelmValues           = false
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          retention                               = "24h"
        }
      }

      grafana = {
        sidecar = {
          dashboards = {
            enabled         = true
            searchNamespace = "ALL"
          }
        }
      }

      # Kind 不暴露這些控制平面元件的 metrics 端點，開著只會一直 scrape 失敗。
      kubeControllerManager = {
        enabled = false
      }
      kubeScheduler = {
        enabled = false
      }
      kubeEtcd = {
        enabled = false
      }
      kubeProxy = {
        enabled = false
      }
    })
  ]

  set_sensitive = [
    {
      name  = "grafana.adminPassword"
      value = var.grafana_admin_password
    }
  ]
}
