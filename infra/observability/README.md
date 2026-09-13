# 模組 F：可觀測性

Prometheus 告警規則、Grafana SIEM 儀表板，以及把 gateway / dataplane 接進 kube-prometheus-stack 的 ServiceMonitor。

指標名稱與標籤以 [`docs/CONTRACT.md`](../../docs/CONTRACT.md) 第 3 節為唯一真實來源，**不得發明或要求服務端更名**。`subject` 一律是 HMAC 假名，告警與面板禁止還原真實身分。

## 套用

需要 Prometheus Operator CRD（由模組 D 的 kube-prometheus-stack 安裝）：

```bash
kubectl apply -k infra/observability
```

Grafana：`make grafana`（預設帳密見 `docs/demo/README.md`）。sidecar 會載入帶 `grafana_dashboard=1` 的 ConfigMap，資料夾註解為 `Aegis`。

## 目錄

```
infra/observability/
├── kustomization.yaml
├── prometheus/
│   ├── rules/
│   │   ├── data-exfiltration.yaml      # 資料外洩 / 遮罩 / KMS
│   │   ├── zero-trust-gateway.yaml     # 驗證、授權、限流、SLO
│   │   ├── microsegmentation.yaml      # Hubble L3/L4/L7
│   │   └── service-health.yaml         # 抓取、副本、KMS 延遲、鏈上呼叫
│   └── servicemonitors/
│       ├── gateway.yaml                # port metrics:9090、路徑 /metrics
│       └── dataplane.yaml              # port http:8000、路徑 /metrics
└── grafana/dashboards/
    ├── siem-overview.json
    ├── data-protection.json
    └── microsegmentation.json
```

## 對模組 D 的假設

現有 PrometheusRule 註解已假設 `ruleSelectorNilUsesHelmValues=false`。ServiceMonitor 同樣需要：

- `prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false`
- 或 selector 能匹配 `release: kube-prometheus-stack`
- `grafana.sidecar.dashboards.enabled=true`，標籤 `grafana_dashboard=1`

ServiceMonitor 放在 `observability`，用 `namespaceSelector.matchNames: [aegis]` 抓應用 Service，不改 `infra/k8s/`。

## 告警一覽（34）

| 檔案 | 則數 | 告警 |
| --- | ---: | --- |
| data-exfiltration.yaml | 8 | 異常解密、解密硬上限、加解密比例、遮罩失效、KMS 錯誤率／暴增、遮罩管線停擺、非上班時段解密 |
| zero-trust-gateway.yaml | 12 | 憑證缺失／偽造、授權探測／枚舉、拒絕比例、限流、5xx、p99、未授權路徑 |
| microsegmentation.yaml | 6 | 策略拒絕、attacker 流量、丟棄比例、Hubble 消失、L7 403、L7 拒絕比例 |
| service-health.yaml | 8 | `AegisServiceDown`、抓取目標缺失、契約指標消失、副本不足、CrashLoop、KMS p99、鏈上失敗率 |

`AegisServiceDown` 名稱不可改：閘道 5xx runbook 會交叉比對它。

## 儀表板（3）

| 標題 | uid | 視覺化面板 | 告警 runbook 對應面板 |
| --- | --- | ---: | --- |
| Aegis / SIEM 總覽 | `aegis-siem-overview` | 16 | 威脅事件時間軸、HTTP 狀態碼分布、限流 |
| Aegis / 資料保護 | `aegis-data-protection` | 14 | 異常解密 subject 排行、KMS 操作速率、遮罩失效 stat |
| Aegis / 微分段 | `aegis-microsegmentation` | 11 | 策略拒絕熱點、L7 放行／拒絕比例 |

列（row）僅作分組，不計入上表。

## 本機驗證

```bash
# 儀表板 JSON
jq empty infra/observability/grafana/dashboards/*.json

# 抽出 PrometheusRule.spec 後用 promtool 檢查
# （需本機 promtool 或 docker.io/prom/prometheus）
```

只改本目錄。套用前請確認模組 D 已裝好 Operator 與 Grafana sidecar。
