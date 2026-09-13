# PR 說明

## 這個 PR 解決什麼問題

<!-- 一到三句話說明動機與影響範圍。不必重述 diff，reviewer 會自己看程式碼。 -->

## 變更類型

- [ ] 新功能
- [ ] 修正缺陷
- [ ] 重構（不改變外部行為）
- [ ] 安全強化
- [ ] 基礎設施 / CI
- [ ] 文件

## 影響的模組

<!-- 依 docs/CONTRACT.md 第 8 節的路徑所有權勾選。跨模組變更請在下方說明協調結果。 -->

- [ ] 模組 A 合約 `contracts/`
- [ ] 模組 B 閘道 `services/gateway/`
- [ ] 模組 C 資料面 `services/dataplane/`
- [ ] 模組 D 基礎設施 `infra/terraform/`
- [ ] 模組 E 網路策略 `infra/k8s/`
- [ ] 模組 F 可觀測性 `infra/observability/`
- [ ] 模組 G 文件與 demo `docs/`、`scripts/demo-*.sh`
- [ ] CI `.github/workflows/`
- [ ] 專案骨架（根目錄檔案、`scripts/bootstrap.sh`、`scripts/doctor.sh`）

---

## 安全檢查清單

> 每一項都必須明確回答。勾「是」不代表 PR 會被擋下，只代表 reviewer 需要多看一眼。
> **勾了「是」卻沒有在下方補充說明的 PR 會被退回。**

### 1. 機密與憑證

- [ ] 本 PR **新增或變更了機密**（token、私鑰、憑證、連線字串、種子詞）
- [ ] 我已確認沒有任何真實憑證進入版控（含 `.env`、測試 fixture、註解、commit 訊息、測試日誌）
- [ ] 新增的機密是透過 Kubernetes Secret 或部署期注入，而非寫死在程式碼或映像層裡
- [ ] 若新增了環境變數，我已同步更新 `docs/CONTRACT.md` 第 5 節與 `.env.example`

<!-- 若上方第一項為「是」，請說明機密的來源、輪替方式與最小權限範圍： -->

### 2. 網路策略與微分段

- [ ] 本 PR **影響網路策略**（新增服務、埠、對外路由、服務間呼叫、namespace）
- [ ] 新增的通訊路徑已在 `infra/k8s/policies/` 明確放行，而非依賴預設允許
- [ ] 我確認 default-deny 的前提沒有被放寬（沒有新增 wildcard 或 `toEntities: all`）
- [ ] 若新增了對 dataplane 的端點，L7 policy 的放行清單已同步更新

<!-- 若上方第一項為「是」，請說明新的資料流方向、來源身分（ServiceAccount）與被放行的 method + path： -->

### 3. KMS 與加密流程

- [ ] 本 PR **更動了 KMS 或加密流程**（金鑰用途、encryption context、信封格式、driver、輪替邏輯）
- [ ] `aad` 與 KMS encryption context 仍完全一致（金鑰用途綁定未被破壞）
- [ ] 密文信封格式仍符合 `docs/CONTRACT.md` 第 6 節；若有版本變更，`v` 欄位已遞增且保留舊版解密路徑
- [ ] 三個 `KeyProvider` driver（localstack / vault / aws）都通過同一組合約測試

<!-- 若上方第一項為「是」，請說明變更內容與既有密文的向後相容策略： -->

### 4. 威脅模型

- [ ] 本 PR **需要更新威脅模型**（新增信任邊界、外部依賴、對外攻擊面、權限提升路徑）
- [ ] 我已更新 `docs/` 中的 STRIDE 威脅建模與 CCSP 控制項對照表
- [ ] 重大架構決策已補上 ADR（`docs/adr/`）

<!-- 若上方第一項為「是」，請說明新增的攻擊面與對應的緩解措施： -->

### 5. 資料最小化與去識別化

- [ ] 我確認新增的日誌、Prometheus 標籤與錯誤訊息中**沒有原始 PII、金鑰材料或完整 JWT**
- [ ] 所有 `subject` 標籤與日誌欄位都是 HMAC 假名（`sub_` 前綴），而非真實身分識別資料
- [ ] 新增的 Prometheus 標籤基數（cardinality）有界，不會用使用者輸入當標籤值

---

## 驗證方式

- [ ] `make fmt` 通過
- [ ] `make test` 通過（受影響模組的測試）
- [ ] `make scan` 通過（若變更涉及映像、IaC 或合約）
- [ ] 新增或修改的函式都有對應的單元測試
- [ ] 若變更涉及網路策略，已用 `scripts/attack-sim/` 或 Hubble 實證攔截行為

<!-- 貼上關鍵的驗證輸出（測試摘要、hubble observe 的 DROPPED 事件、Grafana 截圖等）： -->

## Reviewer 需要特別注意的地方

<!-- 指出你自己也不太確定的部分，或希望被挑戰的設計取捨。 -->
