# CI Workflows

Aegis-Enclave 的五條必過品質閘門。每條只在自己守護的路徑變動時觸發，權限預設只有 `contents: read`，需要上傳 SARIF 的 job 才額外開 `security-events: write`。同一分支的新推送會取消仍在跑的舊執行。

| Workflow | 守護路徑 | 做什麼 | 本機等價 |
| --- | --- | --- | --- |
| [`contracts.yml`](contracts.yml) | `contracts/**` | forge fmt / build / test / coverage + Slither SARIF + ABI 契約 | `make test-contracts`、`make scan-contracts` |
| [`gateway-go.yml`](gateway-go.yml) | `services/gateway/**` | go vet / golangci-lint / race test / govulncheck + 映像 Trivy | `make test-gateway`、`make scan-images` |
| [`dataplane-py.yml`](dataplane-py.yml) | `services/dataplane/**` | ruff / mypy / pytest 覆蓋率門檻 / pip-audit + 映像 Trivy | `make test-dataplane`、`make scan-images` |
| [`iac.yml`](iac.yml) | `infra/terraform/**`、`infra/k8s/**`、`infra/observability/**` | terraform fmt / init / validate + Trivy config SARIF | `terraform -chdir=infra/terraform validate`、`make scan-iac` |
| [`e2e-kind.yml`](e2e-kind.yml) | 服務、k8s、terraform、`scripts/attack-sim/**`、[`.github/kind/`](../kind/) | Kind + Cilium 1.20.1 + `scripts/attack-sim/run.sh`；失敗上傳診斷 | `make up` 後執行 `scripts/attack-sim/run.sh` |

## 共用慣例

- **Action 版本釘死**：大版本或 patch 標籤（例如 `actions/checkout@v7`、`aquasecurity/trivy-action@v0.36.0`），由 Dependabot 的 `github-actions` ecosystem 週更。
- **路徑過濾**：避免改一份 README 就燒掉五條 runner。
- **concurrency**：`group: ${{ github.workflow }}-${{ github.ref }}`、`cancel-in-progress: true`。
- **最小權限**：workflow 層 `contents: read`；SARIF 上傳才在該 job 開 `security-events: write`。
- **註解**：一律繁體中文，說明「為什麼」而不只是「做什麼」。

## Kind 叢集（e2e）

組態在 [`.github/kind/cluster.yaml`](../kind/cluster.yaml)：

- 叢集名稱 `aegis-enclave`
- 節點映像 `kindest/node:v1.31.0`
- `disableDefaultCNI: true`（Cilium 接管）
- `kubeProxyMode: iptables`（關閉 KPR，對齊本機 ADR）
- 1 個 control-plane + 2 個 worker

`e2e-kind` 用 `helm/kind-action` 建立叢集時 `wait: 0s`，因為沒有 CNI 時節點不會 Ready。裝上 Cilium 1.20.1（含 Hubble Relay）後再 `kubectl wait --for=condition=Ready`。失敗時把節點、Pod、Cilium、應用與 attacker 日誌打成 `e2e-kind-diagnostics` artifact。

本機 `make up` 仍走 Terraform，不讀這份 Kind 組態。

## Branch protection 建議

在 `main` 把下列五個檢查設為 required：`contracts`、`gateway-go`、`dataplane-py`、`iac`、`e2e-kind`。並開啟 Require review from Code Owners。

路徑過濾導致某條 workflow 沒被觸發時，GitHub 會把該 required check 視為通過（skipped = success）。若要每張 PR 都「登記」五條檢查，請改成 workflow 永遠跑、用 job 級 `if` 跳過昂貴步驟。

## 本機驗證 workflow 語法

```bash
# 安裝：brew install actionlint
actionlint
```

只檢查 `.github/workflows/*.yml`，不需要網路，也不會改遠端。
