# 模組 E：Kubernetes 部署與 Cilium 微分段

本目錄是 Aegis-Enclave 的網路信任邊界。應用工作負載在 `base/`，
Cilium 策略在 `policies/`。`aegis` 與 `attacker` 兩個 namespace 由本模組建立，
Terraform（模組 D）不會建它們。

## 部署順序

先 `make bootstrap` 與 `make doctor`。**不要先自動 `make up`**，它會建立 Kind 叢集並跑 Terraform。

```bash
# 1. 模組 D 拉起 Kind + Cilium + kube-prometheus-stack（自行決定時機）
make up          # 或 terraform apply 後再走下面步驟

# 2. 套用本目錄前，JWKS 必須存在。Kind/demo 已內建於 base/jwks.demo.yaml
#    （僅供 Kind/demo，非正式金鑰）。正式環境請先建立自己的 Secret：
#    kubectl -n aegis create secret generic aegis-gateway-jwks \
#      --from-file=jwks.json=path/to/jwks.json
#    沒有這份 Secret 時 gateway /readyz 回 503，rollout 會等滿 180s。

# 3. make deploy 等價於：
kubectl apply -k infra/k8s/base
kubectl apply -k infra/k8s/policies
kubectl -n aegis rollout status deploy/gateway --timeout=180s
kubectl -n aegis rollout status deploy/dataplane --timeout=180s

# 4. 模組 F：Prometheus 規則、ServiceMonitor、Grafana 儀表板
#    （需要模組 D 已裝好 kube-prometheus-stack）
kubectl apply -k infra/observability

# 5. 驗證微分段真的有效（也是 CI e2e-kind 的驗收）
./scripts/attack-sim/run.sh
```

映像必須先 `kind load`（`make images` / `make load`），
`imagePullPolicy: IfNotPresent` 才找得到 `aegis/gateway:dev` 與 `aegis/dataplane:dev`。

## base/ 裡有什麼

| 檔案 | 用途 |
| --- | --- |
| `namespace.yaml` | `aegis`（Pod Security restricted）與 `attacker`（baseline） |
| `gateway.yaml` | 唯一對外入口。`AEGIS_REQUIRE_MTLS=false`（Kind 明文 HTTP），`AEGIS_PSEUDONYM_SALT` 由 Secret 注入 |
| `dataplane.yaml` | 持有金鑰與明文的資料面，不對外曝露 |
| `localstack.yaml` | 離線 KMS，init 建立 `alias/aegis-master` 與 `alias/aegis-pseudonym` |
| `vault.yaml` | Transit 備援後端（**dev 模式，僅供展示**） |
| `anvil.yaml` | Foundry 本地鏈，chainId 31337 |
| `secrets.example.yaml` | demo 用假值（salt / Vault token）；正式環境改 External Secrets / Vault Agent |
| `jwks.demo.yaml` | Kind/demo 用 JWKS 公鑰 Secret（**僅供 Kind/demo，非正式金鑰**） |

所有容器都套 restricted 等級的 `securityContext`：
`runAsNonRoot`、`readOnlyRootFilesystem`、`capabilities.drop: [ALL]`、
`seccompProfile: RuntimeDefault`、`allowPrivilegeEscalation: false`。

## 每條策略防什麼

| 檔案 | 防的攻擊 |
| --- | --- |
| `00-default-deny` | 沒寫 allow 就自動放行的隱性信任 |
| `01-dns-egress` | 用 DNS 當 C2、解析外部主機後外帶資料 |
| `02-gateway-ingress` | 略過閘道或摸到 9090 指標埠 |
| `03-gateway-to-dataplane-l7` | 非閘道直連；或閘道身分打 `/docs`、`/internal/v1/keys` |
| `04-dataplane-egress` | 資料面被 RCE 後把明文/DEK 送到網際網路 |
| `05-metrics-scrape` | 不讓 Prometheus 抓不到指標，也不把 `/metrics` 對全世界開放 |
| `06-attacker-isolation` | 即使 00 被誤刪，attacker 仍進不了 aegis |

L7 只放行契約路徑：

- `GET /internal/healthz`
- `POST /internal/v1/records`
- `GET /internal/v1/records/.*`
- `POST /internal/v1/chain/retire`

刻意不用 `/internal/v1/*`，否則 `/internal/v1/keys` 會被放行。

`05-metrics-scrape` 允許 `observability` namespace 的 Prometheus：

- `GET /metrics` → `dataplane:8000`
- `GET /metrics` → `gateway:9090`

## 自行驗證攔截

```bash
./scripts/attack-sim/run.sh
# 五個情境都必須印 PASS。任一 FAIL 會以非零結束碼退出。

# 即時看核心層證據
make hubble
# 或：hubble observe --verdict DROPPED --follow
```

Kind/demo 的 JWKS 公鑰由 `base/jwks.demo.yaml` 預建（**僅供 Kind/demo，非正式金鑰**），
`kubectl apply -k infra/k8s/base` 會一併建立 `aegis-gateway-jwks`。正式金鑰不可提交；
正式環境請覆蓋為自行產生的公鑰：

```bash
kubectl -n aegis create secret generic aegis-gateway-jwks \
  --from-file=jwks.json=path/to/jwks.json
```
