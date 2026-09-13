# 威脅模型（STRIDE）

本文件是模組 G 的威脅模型。它不是學術練習：每一列都要能指到緩解措施、程式位置，以及哪一支 `scripts/demo-*.sh` 可以當場重現。更新控制項或新增資料流時，應同步改本檔與 [`ccsp-mapping.md`](ccsp-mapping.md)。

## 1. 範圍與假設

**在範圍內**

- Kind 叢集 `aegis-enclave` 內的 gateway、dataplane、Cilium、Hubble、Prometheus/Grafana、LocalStack/Vault/Anvil、`attacker` 命名空間。
- 外部用戶端經閘道進入的 HTTP API（金庫紀錄、碳權退役）。
- 閘道 → 資料面的內部呼叫，以及資料面 → KMS / 鏈的出向。

**不在範圍內**

- 雲端帳號接管、評審筆電本身被植入、實體竊取。
- 主網 / 測試網的 MEV、gas 拍賣（合約只部署在 Anvil `31337`）。
- 完整的人員安全與供應商盡職調查（以 Dependabot + Trivy + Slither 為代表控制）。

**三條已裁定的假設（必須寫進模型，否則緩解會講錯）**

| 編號 | 裁定 | 文件 |
| --- | --- | --- |
| A1 | Kind 展示 `AEGIS_REQUIRE_MTLS=false`。TLN 以無效 JWT / 演算法混淆證明應用層驗證；正式環境必須開 mTLS。 | [ADR 0003](adr/0003-kind-demo-mtls.md) |
| A2 | 請求 `subject` 由閘道用 `AEGIS_PSEUDONYM_SALT` 做 HMAC，經 `X-Aegis-Subject` 傳給資料面。資料面不解析 JWT。 | [ADR 0004](adr/0004-gateway-pseudonym-subject.md) |
| A3 | macOS 上 Cilium `kubeProxyReplacement` 預設關閉。NetworkPolicy 與 Hubble 仍視為有效控制。 | [ADR 0002](adr/0002-ebpf-on-macos.md) |

信任邊界見 README 架構圖：叢集邊緣、`aegis` / `attacker` / `observability` 命名空間、閘道行程、資料面行程、KMS、Anvil。

## 2. 資料流

| ID | 從 → 到 | 資料 | 驗證 |
| --- | --- | --- | --- |
| F1 | 用戶端 → 閘道 `:8080` | JWT、業務 JSON（可能含 PII）、`X-Aegis-Request-ID` | Kind：JWT；正式：mTLS + JWT |
| F2 | 閘道 → 資料面 `:8000` | 已驗證的業務 payload、`X-Aegis-Request-ID`、`X-Aegis-Subject` | Cilium L7 路徑白名單；呼叫者必須是 gateway 身分 |
| F3 | 資料面 → KMS | GenerateDataKey / Decrypt、encryption context | 網路策略出向限制；driver 憑證 |
| F4 | 資料面 → Anvil | `retire` / 讀取 `totalRetired` | 僅資料面可出站到 `:8545` |
| F5 | 閘道／資料面 → stdout / Prometheus | 結構化稽核、`aegis_*` 指標 | `subject` 必為假名；禁止 PII / 完整 JWT / 金鑰 |
| F6 | `attacker` Pod → 資料面 | 探測或重放 | 應在 L3/L4 被丟（Hubble DROPPED） |
| F7 | kubelet → `/healthz` `/readyz` `/internal/healthz` | 探針 | 刻意豁免應用層驗證 |

## 3. STRIDE 分析

圖例：S 假冒、T 竄改、R 否認、I 資訊揭露、D 阻斷、E 權限提升。

### 3.1 F1 用戶端 → 閘道

| 威脅 | 類型 | 緩解 | 位置 | Demo |
| --- | --- | --- | --- | --- |
| 偽造或空白 JWT | S | JWKS 驗簽；issuer / audience 寫死；失敗計入 `aegis_authn_failures_total` | `services/gateway` middleware | TLN 攻擊一 |
| `alg=none` 或 RS256→HS256 | S | 允許的演算法由伺服器寫死，不信任 header | `authn.go` / `TestRejectAlgConfusion` | TLN 攻擊二 |
| 重放過期 token | S | `exp` 必驗；正式環境建議加 `jti` | 閘道 authn | 告警 `AegisAuthnInvalidSignatureDetected` |
| 無客戶端憑證（僅正式環境） | S | `AEGIS_REQUIRE_MTLS=true` | 閘道 + Ingress | TLN 旁白 / ADR 0003 |
| 竄改 body 但不重簽 | T | 驗簽失敗即 401 | 同上 | TLN 攻擊一 |
| 事後否認「我沒打過這支 API」 | R | 結構化 `authz.decision` + `request_id` + `trace_id` | 契約第 4 節 | TLN 稽核幕 |
| 請求 body 含 PII 被中間人看光 | I | 正式環境 TLS 1.3 + mTLS。Kind 綁 `127.0.0.1`，接受本機明文殘餘風險 | ADR 0003、Terraform `host_listen_address` | 各腳本旁白 |
| 暴力打爆閘道 | D | 每假名 subject 限流 20 rps / burst 40 | 閘道 rate limit | TLN 限流幕 |
| 有效 JWT 打退役 | E | Rego 最小權限，analyst 得 403 | 閘道 policy | TLN 越權、ClimateChain 末幕 |

### 3.2 F2 閘道 → 資料面

| 威脅 | 類型 | 緩解 | 位置 | Demo |
| --- | --- | --- | --- | --- |
| 非閘道工作負載冒充內部呼叫 | S | Cilium 只允許 `app.kubernetes.io/name=gateway` 打白名單路徑 | `infra/k8s/policies/` | HackTitan、ForgeHacks |
| 閘道被攻破後掃 `/internal/v1/keys` 或 `/docs` | E / I | L7 非白名單回 403 | 同上 | TLN L7 幕 |
| 客戶端注入 `X-Aegis-Subject` | S | 閘道覆蓋外部同名標頭；資料面不面對外網 | ADR 0004 | TLN 合法請求旁白 |
| 竄改內部 payload | T | 叢集內仍是 HTTP；殘餘風險由網路身分 + 唯讀容器降低。正式環境應在服務間補 mTLS | ADR 0001、0003 | 威脅殘餘見第 4 節 |
| 內部呼叫無稽核 | R | 兩側都寫 `request_id`；資料面指標帶同一假名 subject | 契約第 3、4 節 | FinCyber subject 幕 |

### 3.3 F3 / F4 資料面出向

| 威脅 | 類型 | 緩解 | 位置 | Demo |
| --- | --- | --- | --- | --- |
| 把 DEK 拿到別的 tenant 解密 | T / E | aad ≡ encryption context | 契約第 6 節、ADR 0005 | FinCyber 信封幕 |
| KMS 金鑰政策被改 | T / D | `aegis_kms_errors_total` 告警；token 走 Secret | `data-exfiltration.yaml` | FinCyber 指標幕 |
| 資料面被逼當跳板外連 | I | 出向只放行 LocalStack / Vault / Anvil | `04-dataplane-egress`（模組 E） | HackTitan 策略幕 |
| 碳權雙花 / 重入 | T / E | `retire` + RetirementRegistry；Foundry invariant、Slither | `contracts/` | ClimateChain |
| LocalStack 被當成生產 HSM | I | 文件與 demo 明確降級說明 | ADR 0005、README 已知限制 | FinCyber 生命週期幕 |

### 3.4 F5 可觀測性

| 威脅 | 類型 | 緩解 | 位置 | Demo |
| --- | --- | --- | --- | --- |
| 日誌寫出 PII 或完整 JWT | I | 欄位契約；CI / demo 做負向斷言 | 契約第 4 節 | TLN、FinCyber 日誌幕 |
| 指標 `subject` 高基數爆 Prometheus | D | 先假名化再標籤；規則 `sum by (subject)` | `zero-trust-gateway.yaml` 檔頭 | TLN SIEM |
| Grafana 弱密碼 | S | 密碼 validation ≥ 12 且拒用常見字；僅本機 demo 預設 | Terraform `grafana_admin_password` | demo README |
| 告警疲勞導致真攻擊被忽略 | D | reason / 廣度分級；attacker 零容忍單獨一條 | 三份 PrometheusRule | HackTitan 告警幕 |

### 3.5 F6 攻擊者命名空間

| 威脅 | 類型 | 緩解 | 位置 | Demo |
| --- | --- | --- | --- | --- |
| 橫向移動到 dataplane | E | default-deny + Hubble DROPPED | 模組 E、F | HackTitan 攻擊幕 |
| 攻擊 Pod 在 aegis namespace 起特權容器 | E | PSA `restricted` | `namespace.yaml` | ForgeHacks 第 1–2 幕 |
| 攻擊被丟掉但沒人看見 | R | `hubble_drop_total`、`AegisAttackerNamespaceTrafficDetected` | `microsegmentation.yaml` | HackTitan Hubble / 告警 |

### 3.6 供應鏈與主機

| 威脅 | 類型 | 緩解 | 位置 | Demo |
| --- | --- | --- | --- | --- |
| 映像含未修高危 CVE | T / E | Trivy HIGH/CRITICAL 失敗；distroless 非 root | Makefile `scan-images` | ForgeHacks Trivy |
| 合約邏輯漏洞 | T / E | forge test / fuzz / invariant + Slither SARIF | `contracts/`、CI | ClimateChain |
| 容器逃逸 | E | 非 root、drop ALL、唯讀根檔、禁止提權、不掛 SA token | `gateway.yaml` / `dataplane.yaml` | ForgeHacks |
| IaC 錯誤開放 NodePort 到區網 | I | `host_listen_address` 預設 127.0.0.1；Trivy config | Terraform、`scan-iac` | HackTitan IaC 幕 |
| macOS 開 KPR 導致 CNI 全掛（可用性） | D | KPR 預設 false | ADR 0002 | HackTitan ADR 幕 |

## 4. 殘餘風險

| 風險 | 為何接受 | 補償 |
| --- | --- | --- |
| Kind 上 F1 走明文 HTTP | 無 Ingress / PKI，現場要重現 JWT 攻擊 | 只綁 loopback；旁白強調正式環境 mTLS |
| 閘道持有 `AEGIS_PSEUDONYM_SALT` | 必須在 authN 當下產生假名 | Secret 掛載；外洩只能對已知 `sub` 做彩虹表，拿不到欄位 token 金鑰 |
| 叢集內 F2 仍是 HTTP | Kind 無 mesh | Cilium 身分 + 容器邊界 + 資料面不對外 |
| LocalStack ≠ HSM | 離線、免費、可重現 | 正式切 aws/vault；文件不宣稱 FIPS |
| 關 KPR | macOS 穩定性 | Policy 與 Hubble 仍開；Linux 可 opt-in |
| Anvil 無主網攻擊面 | 比賽範圍 | 不宣稱 MEV / 跨鏈橋安全 |

## 5. 與評審提問的對照

- 「這算零信任嗎？」→ 不信任網路位置。Kind 關的是客戶端憑證，不是「內網放行」。JWT、授權、限流、L7 仍每請求重驗。
- 「日誌怎麼給 SOC 還不洩漏？」→ 假名可 join 不可逆；demo 對身分證做負向斷言。
- 「策略會不會只寫在 YAML？」→ attacker 直連應失敗，Hubble 要看得到 DROPPED，告警要亮。
- 「macOS 能跑 Cilium？」→ 能跑 Policy 與 Hubble；不能預設開 KPR。見 ADR 0002。
