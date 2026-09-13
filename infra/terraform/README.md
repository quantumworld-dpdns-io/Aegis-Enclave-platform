# 模組 D：Terraform 基礎設施

用 Terraform 在本機拉起 HackTitan / 全賽事共用的座艙：**Kind 叢集 + Cilium 1.20.1 + kube-prometheus-stack**。

日常操作請走 repo 根目錄的 `make up` / `make down`，不要直接對這份目錄 `apply`（除非你知道自己在覆寫哪個變數）。

## 會建立什麼、不會建立什麼

| 建立 | 不建立（刻意） |
| --- | --- |
| Kind 叢集 `aegis-enclave`（pin `kindest/node:v1.31.0`） | `aegis` namespace（模組 E `infra/k8s/base` 擁有） |
| Cilium 1.20.1（`disableDefaultCNI=true`） | `attacker` namespace（同上） |
| `observability` namespace + kube-prometheus-stack | 應用程式、CiliumNetworkPolicy、Grafana 儀表板（B/C/E/F） |
| Hubble（drop / flow / http + OpenMetrics） |  |

`kubeconfig` 寫到 [`kubeconfig`](./kubeconfig)（已被根目錄 `.gitignore` 排除）。`Makefile` 的 `KUBECONFIG_PATH` 指向同一個檔案。

## 目錄

```
infra/terraform/
├── versions.tf              # provider 版本鎖定（helm 必須 3.x）
├── variables.tf             # 與 docs/CONTRACT.md 對齊的輸入
├── main.tf                  # 根模組：provider + 三個子模組的編排
├── outputs.tf
├── README.md
└── modules/
    ├── kind-cluster/        # tehcyx/kind
    ├── cilium/              # Helm: cilium 1.20.1
    └── observability/       # CRD 薄 chart → kube-prometheus-stack
```

## 套用順序

1. Kind（`disableDefaultCNI=true`，此時節點 NotReady）
2. `prometheus-operator-crds`（讓 `ServiceMonitor` CRD 先存在）
3. Cilium（CNI 就緒、節點轉 Ready；可建立 Hubble ServiceMonitor）
4. kube-prometheus-stack（`crds.enabled=false`，避免跟步驟 2 搶 CRD）

Cilium 只依賴步驟 2 的 output（`crds_ready`），不會被整個 Prometheus stack 擋住。

為什麼 CRD 要拆開：Cilium 在 `hubble.metrics.serviceMonitor.enabled=true` 時會建立 `ServiceMonitor`。若 CRD 還不存在，Helm 直接失敗。完整 stack 太重，不適合擋在 CNI 前面。

## 關鍵預設值

與 `docs/CONTRACT.md` 第 1 節一致：

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `cluster_name` | `aegis-enclave` | 必須與 Makefile `CLUSTER_NAME` 相同 |
| `node_image` | `kindest/node:v1.31.0` | 不可省略，tehcyx/kind 內建 kind 落後上游 |
| `cilium_version` | `1.20.1` | |
| `enable_kube_proxy_replacement` | `false` | macOS / Docker Desktop 開了 cilium-agent 會 CrashLoop |
| `enable_hubble` | `true` | metrics：`drop` / `flow` / `http` + `enableOpenMetrics` |
| `enable_observability` | `true` | `false` 時連 Cilium ServiceMonitor 一起關 |
| `kube_prometheus_stack_version` | `90.2.0` | |
| `prometheus_operator_crds_version` | `32.0.0` | |
| `prometheus_host_port` | `30090` | 宿主機 → NodePort 30090 |

Prometheus 三個 selector 旗標固定為：

- `ruleSelectorNilUsesHelmValues=false`
- `serviceMonitorSelectorNilUsesHelmValues=false`
- `podMonitorSelectorNilUsesHelmValues=false`

這樣 Cilium 與模組 F 的 `ServiceMonitor` / `PrometheusRule`（沒有 Helm release 標籤）才會被抓到。

## 使用方式

```bash
# 建議：從 repo 根目錄一鍵拉起（會先建映像再 apply 再 deploy）
make up

# 只驗證這份 Terraform（CI / 開發時）
cd infra/terraform
terraform init
terraform fmt -recursive
terraform validate

# 銷毀
make down
```

在 Linux（cgroup v2）上若要完整 eBPF 資料面：

```bash
terraform apply -var enable_kube_proxy_replacement=true
```

這會讓 Kind 的 `kubeProxyMode=none`。**tehcyx/kind 不支援修改既有叢集**，之後要把 KPR 關回去必須 `destroy` 重建，不能 in-place update。

## 已知限制

- **tehcyx/kind 不支援修改既有叢集。** 節點數、CIDR、連接埠對映、`kubeProxyMode`、`node_image` 任一變更都要銷毀重建。見 `modules/kind-cluster/main.tf`。
- **`wait_for_ready` 必須是 false。** `disableDefaultCNI=true` 時節點沒有 CNI，Ready 條件不會滿足；若等待 Ready，Cilium 永遠裝不上去。
- **macOS 預設關閉 KPR。** 詳見 `docs/adr/` 與 `make doctor` 的提示。NetworkPolicy 與 Hubble 不受影響。
- Grafana 預設密碼只適用本機 demo，不要進正式環境。

## 相關契約

- 命名與版本：`docs/CONTRACT.md` 第 1 節
- 路徑所有權：模組 D 只准改 `infra/terraform/`
- 應用與策略部署：`make deploy` → `infra/k8s/`
- 告警與儀表板：模組 F `infra/observability/`
