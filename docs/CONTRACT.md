# 跨模組介面契約

本檔是 Aegis-Enclave 各模組之間的唯一真實來源。九個模組由不同人（或 agent）平行開發，
只要所有人都遵守本契約，就不需要互相等待。**修改本檔前必須先確認不會破壞其他模組。**

## 1. 命名與版本

| 項目 | 值 |
| --- | --- |
| 叢集名稱 | `aegis-enclave` |
| 應用命名空間 | `aegis` |
| 可觀測性命名空間 | `observability` |
| 攻擊模擬命名空間 | `attacker` |
| Cilium 版本 | `1.20.1` |
| Kind node image | `kindest/node:v1.31.0` |
| Go 版本 | `1.23` |
| Python 版本 | `3.12`（容器內；本機 3.14 亦可） |
| Solidity 版本 | `0.8.28` |

## 2. 服務端點

### gateway（Go + Gin）

- 映像：`aegis/gateway:dev`
- ServiceAccount：`gateway-sa`
- Pod 標籤：`app.kubernetes.io/name=gateway`
- 容器埠：
  - `8080` — HTTP 業務流量（`http`）
  - `9090` — Prometheus 指標（`metrics`），路徑 `/metrics`
- 對外路由：
  - `GET  /healthz` — 存活探針，不需驗證
  - `GET  /readyz` — 就緒探針，不需驗證
  - `POST /api/v1/vault/records` — 建立加密紀錄（需驗證）
  - `GET  /api/v1/vault/records/:id` — 讀取並遮罩紀錄（需驗證）
  - `POST /api/v1/carbon/retire` — 觸發碳權退役（需驗證）

### dataplane（Python + FastAPI）

- 映像：`aegis/dataplane:dev`
- ServiceAccount：`dataplane-sa`
- Pod 標籤：`app.kubernetes.io/name=dataplane`
- 容器埠：
  - `8000` — HTTP（業務 + 指標同埠），指標路徑 `/metrics`
- 內部路由（**只允許 gateway 呼叫**，由 Cilium L7 policy 強制）：
  - `GET  /internal/healthz`
  - `POST /internal/v1/records` — 信封加密後寫入
  - `GET  /internal/v1/records/{record_id}` — 解密並套用遮罩
  - `POST /internal/v1/chain/retire` — 經 web3 呼叫合約

> Cilium L7 policy 只放行上述 `/internal/v1/*` 與 `/internal/healthz`。
> 任何其他路徑（例如 `/internal/v1/keys`、`/docs`）一律拒絕，這是微分段 demo 的攔截目標。

### 服務間呼叫

gateway 以環境變數 `AEGIS_DATAPLANE_URL`（預設 `http://dataplane.aegis.svc.cluster.local:8000`）定位 dataplane。
呼叫時必須帶上 `X-Aegis-Request-ID` 標頭以串接分散式追蹤。

## 3. Prometheus 指標契約

所有自訂指標一律以 `aegis_` 為前綴。模組 F 的告警規則與儀表板只依賴下列指標，
**服務端不得擅自更名**。

### gateway 產出

| 指標 | 型別 | 標籤 | 說明 |
| --- | --- | --- | --- |
| `aegis_http_requests_total` | counter | `method`, `route`, `status` | 全部請求計數 |
| `aegis_http_request_duration_seconds` | histogram | `method`, `route` | 請求延遲 |
| `aegis_authn_failures_total` | counter | `reason` | 驗證失敗（`missing_token`/`invalid_signature`/`expired`/`no_client_cert`） |
| `aegis_authz_denied_total` | counter | `subject`, `resource` | 授權politik拒絕 |
| `aegis_ratelimit_throttled_total` | counter | `subject` | 被限流的請求 |

### dataplane 產出

| 指標 | 型別 | 標籤 | 說明 |
| --- | --- | --- | --- |
| `aegis_kms_encrypt_total` | counter | `driver`, `key_id` | 資料金鑰產生次數 |
| `aegis_kms_decrypt_total` | counter | `driver`, `key_id`, `subject` | 資料金鑰解密次數（外洩偵測主指標） |
| `aegis_kms_operation_duration_seconds` | histogram | `driver`, `operation` | KMS 呼叫延遲 |
| `aegis_kms_errors_total` | counter | `driver`, `operation` | KMS 錯誤 |
| `aegis_masking_applied_total` | counter | `field_type` | 成功遮罩的欄位數 |
| `aegis_masking_bypass_total` | counter | `field_type`, `reason` | **遮罩失效**，任何非零都應告警 |
| `aegis_chain_calls_total` | counter | `method`, `status` | 合約呼叫次數 |

`subject` 標籤一律是 HMAC tokenize 後的假名，**絕不可寫入真實身分識別資料**。

## 4. 稽核日誌格式

兩個服務都輸出 JSON 結構化日誌到 stdout，欄位如下：

```json
{
  "ts": "2026-09-13T04:20:00Z",
  "level": "info",
  "service": "gateway",
  "event": "authz.decision",
  "request_id": "01J...",
  "trace_id": "4bf92f...",
  "subject": "sub_9f8a2c...",
  "resource": "/api/v1/vault/records",
  "decision": "allow",
  "reason": "policy:vault_reader"
}
```

`subject` 必須是假名（`sub_` + HMAC-SHA256 前 16 碼十六進位）。
日誌中禁止出現原始 PII、金鑰材料、完整 JWT。

## 5. 環境變數契約

### gateway

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `AEGIS_LISTEN_ADDR` | `:8080` | 業務埠 |
| `AEGIS_METRICS_ADDR` | `:9090` | 指標埠 |
| `AEGIS_DATAPLANE_URL` | `http://dataplane.aegis.svc.cluster.local:8000` | 下游位址 |
| `AEGIS_JWT_ISSUER` | `https://aegis.local` | 預期的 JWT issuer |
| `AEGIS_JWT_AUDIENCE` | `aegis-gateway` | 預期的 audience |
| `AEGIS_JWKS_PATH` | `/etc/aegis/jwks.json` | 驗簽公鑰 |
| `AEGIS_REQUIRE_MTLS` | `true` | 是否強制用戶端憑證 |
| `AEGIS_RATE_LIMIT_RPS` | `20` | 每 subject 每秒請求上限 |
| `AEGIS_RATE_LIMIT_BURST` | `40` | 突發容量 |
| `AEGIS_OTEL_ENDPOINT` | `` | 留空則只走 Prometheus pull |
| `AEGIS_LOG_LEVEL` | `info` | |

### dataplane

| 變數 | 預設 | 說明 |
| --- | --- | --- |
| `AEGIS_KMS_DRIVER` | `localstack` | `localstack` / `vault` / `aws` 三選一 |
| `AEGIS_KMS_KEY_ID` | `alias/aegis-master` | 主金鑰識別碼 |
| `AEGIS_KMS_ENDPOINT` | `http://localstack.aegis.svc.cluster.local:4566` | localstack driver 用 |
| `AEGIS_VAULT_ADDR` | `http://vault.aegis.svc.cluster.local:8200` | vault driver 用 |
| `AEGIS_VAULT_TOKEN` | `` | vault driver 用，由 Secret 掛入 |
| `AEGIS_VAULT_TRANSIT_KEY` | `aegis-master` | |
| `AWS_REGION` | `ap-northeast-1` | aws driver 用 |
| `AEGIS_PSEUDONYM_SALT_KEY_ID` | `alias/aegis-pseudonym` | 假名化 HMAC 金鑰 |
| `AEGIS_CHAIN_RPC_URL` | `http://anvil.aegis.svc.cluster.local:8545` | |
| `AEGIS_CARBON_CONTRACT_ADDR` | `` | 部署後注入 |
| `AEGIS_LOG_LEVEL` | `info` | |

## 6. 密文信封格式

dataplane 寫出的密文一律是下列 JSON 的 base64：

```json
{
  "v": 1,
  "driver": "localstack",
  "key_id": "alias/aegis-master",
  "wrapped_dek": "<base64>",
  "nonce": "<base64, 12 bytes>",
  "ciphertext": "<base64, AES-256-GCM>",
  "aad": {"record_id": "...", "tenant": "...", "purpose": "vault"}
}
```

`aad` 同時作為 AES-GCM 的 additional authenticated data 與 KMS encryption context，
兩者必須完全一致，這是金鑰用途綁定（key purpose binding）的實作依據。

## 7. 智能合約介面

`CarbonCredit`（ERC-1155）與 `RetirementRegistry` 對外暴露：

```solidity
// CarbonCredit
function mintBatch(address to, uint256 projectId, uint256 amount, bytes32 verificationHash) external;
function retire(uint256 projectId, uint256 amount, string calldata beneficiary) external;
function totalRetired(uint256 projectId) external view returns (uint256);

// 事件（dataplane 以此對帳）
event CreditsMinted(uint256 indexed projectId, address indexed to, uint256 amount, bytes32 verificationHash);
event CreditsRetired(uint256 indexed projectId, address indexed by, uint256 amount, string beneficiary);
```

部署腳本須將合約位址寫入 `contracts/deployments/local.json`，格式：

```json
{"chainId": 31337, "CarbonCredit": "0x...", "RetirementRegistry": "0x..."}
```

## 8. 路徑所有權

每個模組只准修改自己的目錄，避免平行開發時互相覆蓋：

- 模組 A 合約 → `contracts/`
- 模組 B 閘道 → `services/gateway/`
- 模組 C 資料面 → `services/dataplane/`
- 模組 D 基礎設施 → `infra/terraform/`
- 模組 E 網路策略 → `infra/k8s/`
- 模組 F 可觀測性 → `infra/observability/`
- 模組 G 文件 → `docs/`、`scripts/demo-*.sh`
- CI → `.github/workflows/`
- 根目錄檔案（`Makefile`、`.gitignore`、`README.md`、`scripts/bootstrap.sh`、`scripts/doctor.sh`）→ 模組骨架擁有
