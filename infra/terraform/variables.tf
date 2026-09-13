# 根模組輸入變數。
#
# 命名與預設值必須與 docs/CONTRACT.md 第 1 節一致：
#   叢集名稱 aegis-enclave / Cilium 1.20.1 / Kind node image kindest/node:v1.31.0。
# 其他模組（B/C/E/F）都以這些值為前提，改動前請先確認契約。

# ---------------------------------------------------------------------------
# 叢集基本設定
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Kind 叢集名稱。必須與 docs/CONTRACT.md 與 Makefile 的 CLUSTER_NAME 一致，否則 kind load docker-image 會找不到叢集。"
  type        = string
  default     = "aegis-enclave"

  validation {
    # Kind 會把叢集名稱塞進 Docker 容器名稱（<name>-control-plane），
    # 所以只允許 DNS-1123 標籤字元，避免建立到一半才被 docker 拒絕。
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name 只能使用小寫英數字與連字號，且必須以英數字開頭與結尾。"
  }
}

variable "node_image" {
  description = "Kind 節點映像（含 Kubernetes 版本）。必須明確指定，因為 tehcyx/kind provider 內建的 kind 版本落後上游，其預設 node image 常常不是我們要的 K8s 版本。契約固定為 kindest/node:v1.31.0。"
  type        = string
  default     = "kindest/node:v1.31.0"

  validation {
    condition     = can(regex("^kindest/node:v\\d+\\.\\d+\\.\\d+", var.node_image))
    error_message = "node_image 必須是 kindest/node:vX.Y.Z 格式（可再帶 @sha256 摘要）。"
  }
}

variable "worker_count" {
  description = "worker 節點數量。預設 2，讓 Cilium 微分段 demo 一定會產生跨節點流量（否則同節點流量走 loopback，Hubble 的 drop 觀測說服力不足）。"
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 5 && floor(var.worker_count) == var.worker_count
    error_message = "worker_count 必須是 0 到 5 之間的整數（本機 Docker 資源有限，超過 5 個節點極易 OOM）。"
  }
}

variable "pod_subnet" {
  description = "Pod CIDR。Cilium 以 ipam.mode=kubernetes 從 node.spec.podCIDR 取得配額，所以這裡設定的值會直接決定 Pod 網段。"
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrhost(var.pod_subnet, 0))
    error_message = "pod_subnet 必須是合法的 CIDR，例如 10.244.0.0/16。"
  }
}

variable "service_subnet" {
  description = "Service CIDR（ClusterIP 配置範圍）。不可與 pod_subnet 重疊。"
  type        = string
  default     = "10.96.0.0/12"

  validation {
    condition     = can(cidrhost(var.service_subnet, 0))
    error_message = "service_subnet 必須是合法的 CIDR，例如 10.96.0.0/12。"
  }
}

variable "kubeconfig_path" {
  description = "kubeconfig 輸出路徑。留空則使用 infra/terraform/kubeconfig，這是 Makefile 的 KUBECONFIG_PATH 指向的位置，改動會讓 make deploy / make grafana 全部失效。"
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# 對外連接埠（Kind extra port mappings）
# ---------------------------------------------------------------------------

variable "host_listen_address" {
  description = "Kind 節點連接埠在宿主機上的綁定位址。預設只綁 127.0.0.1，避免把未經驗證的 demo 叢集暴露到同一個 Wi-Fi 網段（零信任專案自己先別破功）。要從其他機器連入才改成 0.0.0.0。"
  type        = string
  default     = "127.0.0.1"
}

variable "http_host_port" {
  description = "宿主機對映到 control-plane 80 埠的連接埠（給 ingress / Gateway API 用）。"
  type        = number
  default     = 80
}

variable "https_host_port" {
  description = "宿主機對映到 control-plane 443 埠的連接埠（給 ingress / Gateway API 用）。"
  type        = number
  default     = 443
}

variable "prometheus_host_port" {
  description = "宿主機對映到 Prometheus NodePort 30090 的連接埠。這是 port-forward 之外的備援存取路徑，demo 時若 port-forward 斷線可直接打 http://127.0.0.1:30090。"
  type        = number
  default     = 30090
}

# ---------------------------------------------------------------------------
# Cilium
# ---------------------------------------------------------------------------

variable "cilium_version" {
  description = "Cilium Helm chart / 映像版本。契約固定為 1.20.1，模組 E 的 CiliumNetworkPolicy 與模組 F 的告警規則都以此版本的 Hubble 指標為前提。"
  type        = string
  default     = "1.20.1"

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+$", var.cilium_version))
    error_message = "cilium_version 必須是 X.Y.Z 格式的語意化版本。"
  }
}

variable "cilium_repository" {
  description = "Cilium Helm repository。預設用官方 HTTP repo；若公司網路擋 helm.cilium.io，可改成 OCI 位址 oci://quay.io/cilium/charts 並把 cilium_chart 設為 cilium。"
  type        = string
  default     = "https://helm.cilium.io/"
}

variable "enable_kube_proxy_replacement" {
  description = <<-EOT
    是否啟用 Cilium kube-proxy replacement（KPR）與 Socket LB。

    **預設 false，這是刻意的。** KPR 與 Socket LB 需要：
      1. 宿主機啟用 cgroup v2（unified hierarchy）；
      2. Kind 節點容器的 cgroup namespace 必須與宿主機不同（否則 Cilium 會掛在錯誤的 cgroup root）。
    macOS 的 Docker Desktop（LinuxKit VM）通常無法同時滿足這兩點，開啟後 cilium-agent 會
    反覆 CrashLoopBackOff，整個 make up 卡死。

    只有在 Linux 宿主機（cgroup v2 + systemd）上，且確認 `docker info | grep -i cgroup` 顯示
    "Cgroup Version: 2" 時才建議開啟。開啟時 Kind 會同時把 kube-proxy 關掉
    （kubeProxyMode = "none"），所以之後不能在同一座叢集把此開關關回去 —— 必須 destroy 重建。
  EOT
  type        = bool
  default     = false
}

variable "enable_hubble" {
  description = "是否啟用 Hubble（含 Relay 與 UI）。模組 F 的儀表板與 make hubble 都依賴它，關閉後微分段 demo 就看不到 DROPPED 判定，正常情況請保持 true。"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# 可觀測性
# ---------------------------------------------------------------------------

variable "enable_observability" {
  description = "是否安裝 kube-prometheus-stack 與 Prometheus Operator CRDs。設為 false 時會連同 Cilium/Hubble 的 ServiceMonitor 一起關閉，避免在沒有 CRD 的叢集上安裝失敗。"
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack Helm chart 版本（prometheus-community repo）。"
  type        = string
  default     = "90.2.0"
}

variable "prometheus_operator_crds_version" {
  description = "prometheus-operator-crds Helm chart 版本。這個 chart 只含 CRD，會在裝 Cilium 之前先套用，好讓 Cilium 的 ServiceMonitor 有 CRD 可用（詳見 main.tf 的說明）。升級 kube_prometheus_stack_version 時請同步檢查此版本。"
  type        = string
  default     = "32.0.0"
}

variable "grafana_admin_password" {
  description = "Grafana admin 密碼。預設值只適用於本機 demo；正式環境請改用外部 Secret（grafana.admin.existingSecret）或 External Secrets Operator，不要把密碼放進 tfvars 或版控。"
  type        = string
  default     = "aegis-demo-not-for-prod"
  sensitive   = true

  validation {
    # 明確拒絕 admin/password 這類預設弱密碼：Grafana 對外一開就是最容易被撿走的入口，
    # 且 CCSP Domain 5 的稽核項目會直接抓這個。
    condition = length(var.grafana_admin_password) >= 12 && !contains(
      ["admin", "password", "grafana", "prom-operator"],
      lower(var.grafana_admin_password)
    )
    error_message = "grafana_admin_password 至少 12 字元，且不可是 admin/password/grafana/prom-operator 這類預設弱密碼。"
  }
}

variable "expose_prometheus_nodeport" {
  description = "是否把 Prometheus Service 改成 NodePort 30090。搭配 Kind 的 extra port mapping，可以不用 port-forward 直接從宿主機存取；正式環境絕對不要這樣做。"
  type        = bool
  default     = true
}
