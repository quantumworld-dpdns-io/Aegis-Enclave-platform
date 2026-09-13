# Cilium 1.20.1 CNI + Hubble。
#
# kubeProxyReplacement 預設關閉：macOS Docker Desktop（LinuxKit VM）通常無法同時滿足
# cgroup v2 unified hierarchy 與獨立 cgroup namespace，開啟後 cilium-agent 會 CrashLoop。
# NetworkPolicy 與 Hubble 在 KPR=false 時仍然完整可用，這正是 demo 需要的能力。
#
# Hubble metrics 固定含 drop / flow / http，並開啟 OpenMetrics：
#   drop —— 模組 E 微分段攔截的主觀測（hubble_drop_total）
#   flow —— 允許/拒絕流量基線
#   http —— L7 策略（method + path）的判定依據
# enableOpenMetrics 讓 Prometheus 能用 exemplars / 標準 OpenMetrics 解析。

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = var.cilium_repository
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  wait             = true
  atomic           = true
  timeout          = 600
  cleanup_on_fail  = true
  create_namespace = false

  values = [
    yamlencode({
      cluster = {
        name = var.cluster_name
      }

      ipam = {
        # 從 node.spec.podCIDR 配址，對齊 Kind networking.podSubnet。
        mode = "kubernetes"
      }

      kubeProxyReplacement = var.enable_kube_proxy_replacement

      # Kind 控制平面容器的穩定 DNS。CNI 尚未就緒時 kube-proxy / CoreDNS 都還不可靠，
      # 直接打 API Server 可避免 cilium-agent 啟動期因連不上 apiserver 而重啟。
      k8sServiceHost = "${var.cluster_name}-control-plane"
      k8sServicePort = 6443

      hubble = {
        enabled = var.enable_hubble
        relay = {
          enabled = var.enable_hubble
        }
        ui = {
          enabled = var.enable_hubble
        }
        metrics = {
          enabled           = var.enable_hubble ? ["drop", "flow", "http"] : []
          enableOpenMetrics = var.enable_hubble
          serviceMonitor = {
            enabled = var.enable_hubble && var.enable_service_monitors
          }
        }
      }

      prometheus = {
        enabled = var.enable_service_monitors
        serviceMonitor = {
          enabled = var.enable_service_monitors
        }
      }

      operator = {
        replicas = 1
        prometheus = {
          enabled = var.enable_service_monitors
          serviceMonitor = {
            enabled = var.enable_service_monitors
          }
        }
      }
    })
  ]

  lifecycle {
    # 引用 prometheus_crds_ready：根模組傳入的是 CRD helm_release.id，
    # 因此 Cilium 只會等到 CRD 就緒，不會被整個 kube-prometheus-stack 擋住。
    precondition {
      condition     = length(var.prometheus_crds_ready) > 0
      error_message = "prometheus_crds_ready 不可為空（安裝時為 CRD release id，關閉可觀測性時為 disabled）。"
    }
  }
}
