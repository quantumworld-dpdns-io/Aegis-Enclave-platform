# ADR 0001：閘道與資料面分離

- 狀態：已採納
- 日期：2026-09-13
- 決策者：架構仲裁

## 背景

金融與 ESG 工作負載同時需要「誰可以進來」與「資料怎麼被保護」。若把驗簽、授權、加解密、鏈上呼叫塞進同一個行程，任何一次 RCE 就同時拿到身分決策權與金鑰材料。五場比賽又要求同一套程式碼講出不同故事，職責若不切開，demo 敘事也會黏在一起。

## 決策

把系統切成兩個獨立部署單元，中間只留一條被強制的內部路徑：

| 單元 | 職責 | 明確不做 |
| --- | --- | --- |
| `services/gateway`（Go + Gin） | mTLS（正式環境）、JWT/SBT 驗簽、Rego 授權、每 subject 限流、OTel、假名 subject | 不持有 KMS 憑證、不解密業務資料、不直連鏈 |
| `services/dataplane`（Python + FastAPI） | 信封加密、PII 遮罩、KMS、碳權合約呼叫 | 不對外曝露、不驗 JWT、不自行推導呼叫者身分 |

服務間呼叫由 Cilium L7 只放行 `/internal/v1/*` 與 `/internal/healthz`。閘道以 `X-Aegis-Request-ID` 串追蹤，以 `X-Aegis-Subject` 傳遞已假名化的主體（見 ADR 0004）。

## 後果

- 任一側被攻破都無法單獨取得「合法身分 + 明文資料」。
- 五場比賽只換 `scripts/demo-*.sh` 與 `docs/demo/*.md`，程式碼零重寫。
- 多一個網路 hop 與兩份映像；用契約第 2、3、4 節把介面釘死以換取平行開發。
- Kind 展示關閉閘道 mTLS（ADR 0003），但 L7 策略與 JWT 鏈不受影響。

## 替代方案

- **單一巨石服務**：demo 較好講，但不符合縱深防禦，也無法同時服務 TLN（閘道）與 FinCyber（資料面）。
- **服務網格自動 mTLS 取代應用層閘道**：Kind + Docker Desktop 上 Istio/Linkerd 過重，且無法展示演算法混淆這類應用層考點。
