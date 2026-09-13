# CCSP 控制項對照

本表把 (ISC)² CCSP 六大領域中，本專案實際做得到、且能在 demo 重現的控制項對到倉庫路徑。領域 6（法律、風險、合規）只列與日誌去識別化、授權邊界直接相關的實作，不假裝有完整的法遵計畫。

評審若拿官方 CBK 逐條對，請用「控制意圖」而不是條文編號——不同年版用詞不同，意圖不變。

## Domain 1｜雲端概念、架構與設計

| 控制意圖 | 本專案做法 | 證據 |
| --- | --- | --- |
| 職責分離 / 縱深防禦 | 閘道只做身分與政策，資料面只做密碼學與鏈。見 ADR 0001 | 架構圖、兩份 Deployment |
| 信任邊界清楚 | 三個命名空間：`aegis` restricted、`attacker` baseline、`observability` 由 Helm 建 | `infra/k8s/base/namespace.yaml` |
| 共享責任可解釋 | Kind 模擬 IaaS：我們負責映像、政策、KMS driver 選擇；Docker/Kind 負責節點 | README「已知限制」 |
| 設計決策可審計 | ADR 0001–0005 | `docs/adr/` |

**對應 demo**：任何一場開場的架構旁白；HackTitan 的 IaC 幕把「可重現的設計」具象化。

## Domain 2｜雲端資料安全

| 控制意圖 | 本專案做法 | 證據 |
| --- | --- | --- |
| 資料分類 | vault 紀錄視為 PII / 金融資料；碳權退役視為高價值資產操作 | 閘道 Rego 把 retire 從 analyst 拿掉 |
| 靜態加密 | 信封：本地 AES-256-GCM，DEK 由 KEK 包裝後落地 | 契約第 6 節、ADR 0005 |
| 金鑰用途綁定 | `aad` ≡ KMS encryption context（`record_id`/`tenant`/`purpose`） | 資料面 KeyProvider 合約測試 |
| 金鑰分離與輪替 | 主金鑰 `alias/aegis-master` 與欄位假名化 `alias/aegis-pseudonym` 分開 | dataplane Deployment env |
| 傳輸中加密 | 正式環境閘道 mTLS + TLS 1.3；Kind 關 mTLS（ADR 0003）並綁 loopback | `gateway.yaml`、ADR 0003 |
| 去識別化 / 最小化 | 請求 subject：閘道 `AEGIS_PSEUDONYM_SALT` → `X-Aegis-Subject`。欄位 token：資料面 HMAC。日誌禁 PII | ADR 0004、契約第 4 節 |
| 資料外洩偵測 | 異常解密速率、遮罩失效、加解密比失衡 | `data-exfiltration.yaml` |

**對應 demo**：[`scripts/demo-fincyber.sh`](../scripts/demo-fincyber.sh)。TLN 的日誌負向斷言是同一控制的第二個視角。

## Domain 3｜雲端平台與基礎設施安全

| 控制意圖 | 本專案做法 | 證據 |
| --- | --- | --- |
| 基礎設施即程式碼 | Terraform 拉 Kind + Helm（Cilium、kube-prometheus-stack），版本釘死 | `infra/terraform/` |
| 計算資源強化 | 非 root、drop ALL、唯讀根檔、禁止提權、seccomp RuntimeDefault | `gateway.yaml` / `dataplane.yaml` |
| 特權管理 | PSA restricted；SA 不掛 token；禁止 hostNetwork/PID/IPC | `namespace.yaml` |
| 映像完整性 | 多階段 distroless；Trivy HIGH/CRITICAL 失敗 | `make scan-images` |
| 網路隔離 / 微分段 | Cilium default-deny + L7 路徑白名單 | `infra/k8s/policies/` |
| 管理平面保護 | kubeconfig 寫在 repo 內路徑、不污染 `~/.kube`；API 不對區網開放 | Makefile `KUBECONFIG_PATH` |
| 虛擬化 / eBPF 限制誠實揭露 | macOS 預設關 KPR，Policy 與 Hubble 仍可用 | [ADR 0002](adr/0002-ebpf-on-macos.md) |

**對應 demo**：[`scripts/demo-forgehacks.sh`](../scripts/demo-forgehacks.sh)（主機／容器）、[`scripts/demo-hacktitan.sh`](../scripts/demo-hacktitan.sh)（IaC + 網路）。

## Domain 4｜雲端應用程式安全

| 控制意圖 | 本專案做法 | 證據 |
| --- | --- | --- |
| 安全 SDLC | 單元 / fuzz / invariant + 覆蓋率；警告當錯誤 | `contracts/foundry.toml` |
| 靜態分析 | Slither 容器化執行，CI 上傳 SARIF | `make scan-contracts` |
| 身分整合進應用 | JWT/SBT 驗簽、演算法寫死、Rego 授權 | 閘道 middleware |
| 安全失敗（fail-closed） | 政策載不進來就拒絕；遮罩失敗不得回明文 | 告警 runbook、ADR 0005 |
| API 最小曝露 | 資料面無對外 Service 路徑；`/docs` 也被 L7 擋 | 契約第 2 節 |
| 相依管理 | Dependabot 六個 ecosystem；Go 1.23 / Python 3.12 / solc 0.8.28 釘版本 | 契約第 1 節 |

**對應 demo**：[`scripts/demo-climatechain.sh`](../scripts/demo-climatechain.sh)；TLN 的 alg confusion 是應用層考點。

## Domain 5｜雲端安全營運

| 控制意圖 | 本專案做法 | 證據 |
| --- | --- | --- |
| 日誌完整性與有用性 | JSON 結構化；必含 `ts`/`event`/`request_id`/`subject`/`decision` | 契約第 4 節 |
| 身分去識別但仍可分析 | 決定論假名，SOC 可 join 不能反推 | ADR 0004 |
| 指標與告警 | `aegis_*` 名稱鎖定；驗證失敗、授權拒絕、限流、解密異常、策略丟包 | `infra/observability/prometheus/rules/` |
| 事件偵測與回應 | 每條告警都有「發生什麼 / 為什麼重要 / 可能原因 / runbook」 | 三份 PrometheusRule 註解 |
| 安全與可用性一併量測 | 5xx、p99、限流風暴 | `zero-trust-gateway.yaml` SLO 組 |
| 變更可重現 | `make up` / `make deploy`；demo 支援 `--dry-run` 預演 | Makefile、`scripts/demo-*.sh` |
| 紅隊驗證進營運 | `attacker` 命名空間 + Hubble + 零容忍告警 | HackTitan、`microsegmentation.yaml` |

**對應 demo**：[`scripts/demo-tln.sh`](../scripts/demo-tln.sh) 主場；FinCyber / HackTitan 共用同一套 SIEM、不同面板。

## Domain 6｜法律、風險與合規（節錄）

| 控制意圖 | 本專案做法 | 證據 |
| --- | --- | --- |
| 個資處理最小化 | 日誌與指標不存原值；回應遮罩 | FinCyber 負向斷言 |
| 稽核證據可交給第三方 | 假名 + 固定欄位，無需 NDA 就能給評審看 stdout | 契約第 4 節 |
| 風險接受有紀錄 | Kind 明文、LocalStack、關 KPR 都寫進 ADR 與威脅模型殘餘表 | ADR 0002/0003/0005 |

本專案是黑客松作品，**不宣稱**符合 PCI DSS、GDPR 或任何認證。對照表只證明控制意圖有落地。

## 賽事 × Domain 速查

| 賽事 | 主 Domain | 腳本 | 主持稿 |
| --- | --- | --- | --- |
| TLN Hackathon | 5 | `scripts/demo-tln.sh` | [demo/tln.md](demo/tln.md) |
| Financial Cybersecurity | 2（輔 5） | `scripts/demo-fincyber.sh` | [demo/fincyber.md](demo/fincyber.md) |
| ForgeHacks | 3（輔 5） | `scripts/demo-forgehacks.sh` | [demo/forgehacks.md](demo/forgehacks.md) |
| IEEE ClimateChain | 4 | `scripts/demo-climatechain.sh` | [demo/climatechain.md](demo/climatechain.md) |
| HackTitan | 3 / 5 | `scripts/demo-hacktitan.sh` | [demo/hacktitan.md](demo/hacktitan.md) |
