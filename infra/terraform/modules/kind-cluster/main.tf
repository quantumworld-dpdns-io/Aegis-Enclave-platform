# Kind 叢集。
#
# 【tehcyx/kind 不支援修改既有叢集】
# 官方文件原文：This can be used to create and delete Kind clusters.
# It does NOT support modification to an existing kind cluster.
# 因此任何 kind_config 變更（節點數、CIDR、連接埠對映、kubeProxyMode、node_image）
# 都不會 in-place update，必須 terraform destroy 後重建。把 enable_kube_proxy_replacement
# 從 false 改 true（或反向）也一樣 —— 契約裡寫死「必須 destroy 重建」就是這個原因。
#
# 【為什麼必須 pin node_image】
# tehcyx/kind 內建的 kind 二進位永遠落後上游（撰寫時 provider 停在 kind 0.31、
# 上游已是 0.33）。若不指定 node_image，會拿到 provider 打包當下的預設 K8s 版本，
# 而不是契約的 kindest/node:v1.31.0，後續模組 E 的 PSA enforce-version=v1.31 會對不齊。
#
# 【為什麼 wait_for_ready=false】
# disableDefaultCNI=true 時節點沒有 CNI，Ready 條件永遠不會滿足。
# 若 wait_for_ready=true，provider 會空等控制平面 Ready 直到逾時，Cilium 永遠裝不上去。
# kind create 即使不加 --wait 也會在 API Server 可連時回傳 kubeconfig，Helm 可以接著跑。

resource "kind_cluster" "this" {
  name            = var.cluster_name
  node_image      = var.node_image
  kubeconfig_path = var.kubeconfig_path
  wait_for_ready  = false

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    networking {
      # 關掉 kindnet，改由 Cilium 當 CNI。這是 Hubble / NetworkPolicy demo 的前提。
      disable_default_cni = true
      pod_subnet          = var.pod_subnet
      service_subnet      = var.service_subnet
      # KPR 開啟時必須連 kube-proxy 一起拿掉，否則兩邊搶 Service 資料面。
      # 此欄一旦寫入就無法再改（見檔案開頭註解），預設維持 iptables。
      kube_proxy_mode = var.kube_proxy_replacement ? "none" : "iptables"
    }

    node {
      role = "control-plane"

      extra_port_mappings {
        container_port = 80
        host_port      = var.http_host_port
        listen_address = var.host_listen_address
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = var.https_host_port
        listen_address = var.host_listen_address
        protocol       = "TCP"
      }

      # NodePort 30090 開在每個節點上；對映 control-plane 容器埠即可從宿主機打到 Prometheus。
      dynamic "extra_port_mappings" {
        for_each = var.expose_prometheus_nodeport ? [var.prometheus_host_port] : []
        content {
          container_port = extra_port_mappings.value
          host_port      = extra_port_mappings.value
          listen_address = var.host_listen_address
          protocol       = "TCP"
        }
      }
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}
