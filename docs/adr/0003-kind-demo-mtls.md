# ADR 0003：Kind 展示關閉閘道 mTLS，正式環境強制開啟

- 狀態：已採納
- 日期：2026-09-13
- 決策者：架構仲裁
- 參照：`infra/k8s/base/gateway.yaml` 的 `AEGIS_REQUIRE_MTLS`、`docs/CONTRACT.md` 第 5 節、`scripts/demo-tln.sh`

## 背景

契約把閘道 8080 定義為業務埠，並把 `AEGIS_REQUIRE_MTLS` 預設值寫成 `true`。這在正式環境是對的：用戶端憑證在 TLS 交握就被要求，攻擊者連應用層都到不了。

本機 Kind 叢集卻沒有 Ingress、沒有 cert-manager、沒有 service mesh。8080 對應的是容器內明文 HTTP。若在這裡強制用戶端憑證：

- 所有 `curl` 與 kubelet 以外的探測都會在 TLS 層失敗；
- 評審筆電還要先發一套 PKI，現場十分鐘會耗在憑證而不是威脅攔截；
- `/healthz` 雖豁免驗證，但業務路徑會讓整場 TLN 變成「連不上」，而不是「被拒絕」。

同時，TLN 真正要打的分數是 JWT 驗簽、演算法混淆、授權與稽核，這些都不依賴 mTLS。

## 決策

- **Kind 展示清單**把 `AEGIS_REQUIRE_MTLS` 設為 `false`。關掉的只是「要求用戶端憑證」；JWT 驗簽、Rego、限流、假名化全部仍開。
- **正式環境**必須改回 `true`，並由 Ingress 或 sidecar 終止 TLS、轉發用戶端憑證。契約預設值維持 `true`，清單覆寫必須在註解與本 ADR 寫明原因。
- **TLN demo** 不演示「無用戶端憑證被拒」這條在 Kind 上無法重現的路徑。改演示：
  - 無效簽章 JWT → 401（`invalid_signature`）
  - 缺少 token → 401（`missing_token`）
  - `alg=none` 與 RS256→HS256 混淆 → 401
- 每一支會打閘道的 demo 腳本，旁白都必須補一句：正式環境開 mTLS。
- 正式環境的呼叫範例以 `demo::show` 展示，避免觀眾以為生產也走明文 HTTP。

## 後果

- 五支腳本在 Kind 上用 `http://127.0.0.1:8080` 即可重現應用層控制。
- 威脅模型把「傳輸層身分」標為正式環境控制項，Kind 路徑的殘餘風險寫清楚（見 `docs/threat-model.md`）。
- 若有人把展示清單原封不動推到可從區網連入的環境，等於自願關閉第一道門。`host_listen_address` 預設綁 `127.0.0.1` 是配套。

## 替代方案

- **Kind 也開 mTLS**：需自建 CA、掛 Secret、改 curl，現場失敗率高，收益只是重複契約已寫明的預設值。
- **用 mkcert + Ingress**：正確，但超出「筆電十分鐘講完」的範圍，列為後續工作，不阻擋本屆比賽。
