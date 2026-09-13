variable "cluster_name" {
  description = "Kind 叢集名稱。"
  type        = string
}

variable "node_image" {
  description = "Kind 節點映像。必須明確 pin，不可依賴 tehcyx/kind 內建預設值。"
  type        = string
}

variable "worker_count" {
  description = "worker 節點數量。"
  type        = number
}

variable "pod_subnet" {
  description = "Pod CIDR。Cilium ipam.mode=kubernetes 會讀 node.spec.podCIDR。"
  type        = string
}

variable "service_subnet" {
  description = "Service CIDR。"
  type        = string
}

variable "kubeconfig_path" {
  description = "kubeconfig 寫出路徑。"
  type        = string
}

variable "host_listen_address" {
  description = "extraPortMappings 在宿主機上的綁定位址。"
  type        = string
}

variable "http_host_port" {
  description = "宿主機對映到 control-plane 80 的連接埠。"
  type        = number
}

variable "https_host_port" {
  description = "宿主機對映到 control-plane 443 的連接埠。"
  type        = number
}

variable "prometheus_host_port" {
  description = "宿主機對映到 Prometheus NodePort 的連接埠。"
  type        = number
}

variable "kube_proxy_replacement" {
  description = "true 時 Kind 會把 kube-proxy 關掉（kubeProxyMode=none），之後不能在同一座叢集關回去。"
  type        = bool
}

variable "expose_prometheus_nodeport" {
  description = "是否建立 Prometheus NodePort 的 extraPortMappings。"
  type        = bool
}
