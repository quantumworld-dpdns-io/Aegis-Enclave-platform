# ADR 0004：請求主體由閘道假名化並以 X-Aegis-Subject 傳遞

- 狀態：已採納
- 日期：2026-09-13
- 決策者：架構仲裁
- 參照：`docs/CONTRACT.md` 第 3、4 節；閘道環境變數 `AEGIS_PSEUDONYM_SALT`

## 背景

契約要求日誌與 Prometheus 的 `subject` 必須是 `sub_` + HMAC-SHA256 前 16 碼十六進位，禁止出現真實身分、完整 JWT 或原始 PII。早期草圖把 HMAC 金鑰放在資料面、由 KMS 的 `alias/aegis-pseudonym` 派生，理由是「金鑰不要放閘道」。

實作一拆開就出現矛盾：

- 閘道先做 authN/authZ，也是第一個要寫 `authz.decision` 的地方。若此時還沒有假名，日誌要嘛寫原始 `sub`，要嘛再打一次資料面，等於為每筆請求加一趟同步 RPC。
- 資料面依 ADR 0001 **不准解析 JWT**。它不該看見 `Authorization`，也就不該自己從 token 重算身分。
- 限流鍵、`aegis_authz_denied_total{subject=...}` 都在閘道。假名必須在進資料面之前就存在。

資料面的 `AEGIS_PSEUDONYM_SALT_KEY_ID` 仍然有用，但用途是 **欄位級 PII tokenization**（身分證、IBAN），不是請求主體。

## 決策

1. **請求主體（who）**：閘道讀取 JWT 的 `sub`（或等價的 SBT 持有者識別），以環境變數 `AEGIS_PSEUDONYM_SALT` 為 HMAC-SHA256 金鑰，輸出 `sub_` + 摘要前 16 碼十六進位。
2. 閘道把該假名寫入結構化日誌與所有帶 `subject` 標籤的指標。
3. 閘道呼叫資料面時帶 **`X-Aegis-Subject`**。資料面只信任這顆標頭（外加 Cilium 保證呼叫者只能是閘道），用來標自己的 KMS / 遮罩指標，**不回源 JWT**。
4. `AEGIS_PSEUDONYM_SALT` 以 Kubernetes Secret 掛入閘道，不進映像、不進版控、不出現在日誌。Kind 展示可用固定 demo 值，正式環境由密鑰管理系統注入並定期輪替。
5. **欄位假名（what）** 仍由資料面用 `alias/aegis-pseudonym` 做決定論 tokenization，與請求主體的 salt 分離，避免一次輪替讓歷史稽核與歷史欄位 token 同時失效。

客戶端不得自行送 `X-Aegis-Subject`；閘道必須覆蓋任何外部帶上來的同名標頭。

## 後果

- 稽核事件可跨閘道／資料面 join（同一假名），但沒有 salt 無法反推。
- 閘道多持有一項密鑰材料，威脅模型把「閘道 salt 外洩」列為獨立威脅：外洩可讓攻擊者對已知 `sub` 做彩虹表，仍拿不到 PII 欄位 token 的金鑰。
- 契約第 5 節目前只列資料面的 `AEGIS_PSEUDONYM_SALT_KEY_ID`。本 ADR 補上閘道 `AEGIS_PSEUDONYM_SALT`；後續若修契約，應把此列加進 gateway 表，但不得在未協調時改 CONTRACT.md。
- 五支 demo 的日誌斷言一律找 `sub_`，不找 email 或 JWT `sub`。

## 替代方案

- **資料面統一計算假名**：閘道日誌會空窗或洩漏原值，否決。
- **雙方各算一次、salt 相同**：資料面仍要看見原始 `sub`，違反 ADR 0001。
- **只用不透明隨機 id**：無法跨請求 join，SIEM 熱點與限流都會失效。
