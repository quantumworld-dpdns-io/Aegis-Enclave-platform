# TLN Hackathon 主持稿

**時間**：2026-09-19 ～ 2026-09-20  
**腳本**：`./scripts/demo-tln.sh`（建議加 `--interactive`）  
**評分主軸**：零信任閘道、自動化攔截、日誌審計與 SIEM（CCSP Domain 5）

## 開場（40 秒）

「我們沒有內網。Kind 這座叢集為了能在筆電上重現，把 `AEGIS_REQUIRE_MTLS` 關掉——因為沒有 Ingress，8080 是 HTTP。正式環境一定開。今天打給各位看的，是關掉傳輸層身分之後，應用層還剩什麼：偽造 JWT、演算法混淆、越權、限流，以及攔截之後的假名稽核。」

指一下 `infra/k8s/base/gateway.yaml` 裡那整段中文註解，再進腳本。

## 分幕口條

1. **健康探針**  
   「先證明服務活著。後面每一個 401 都是被擋，不是掛了。`/healthz` 是刻意豁免，kubelet 沒辦法持證。」

2. **mTLS 裁定**  
   「請看環境變數是 false。這不是省略零信任，是展示環境的誠實限制。正式呼叫長這樣——」停在 `demo::show` 的 curl --cert。「我們把火力留給 JWT。」

3. **偽造 JWT / 缺 token**  
   「簽章用 JWKS 公鑰驗。這串 Bearer 連 base64 都隨便。預期 401，`reason=invalid_signature`。下一發連 header 都沒有，`missing_token`。」

4. **演算法混淆**  
   「兩種經典：`alg=none` 賭你們偷懶；HS256 拿你們公開的 RSA 公鑰當 HMAC 密鑰。我們把允許演算法寫死在伺服器，不讀 header。單元測試叫 `TestRejectAlgConfusion`。」

5. **合法請求與假名**  
   「同一條鏈換成 analyst.jwt。閘道用 `AEGIS_PSEUDONYM_SALT` 對 `sub` 做 HMAC，變成 `sub_` 加十六碼，再用 `X-Aegis-Subject` 傳給資料面。客戶端沒有資格填這顆標頭。」  
   payload 裡的「王小明 / A123456789」是道具，下一幕要證明它沒進日誌。

6. **越權退役**  
   「驗證通過只是入場。analyst 退不了碳權，403，指標 `aegis_authz_denied_total` 的 subject 仍是假名。」

7. **Cilium L7**  
   「假設閘道被拿下。我用它的 Pod 身分打 `/internal/v1/keys`，契約沒放行，HTTP 403。L3 丟掉的那一種留給 HackTitan。」

8. **限流**  
   「鍵是假名不是 IP。六十發，burst 40，之後 429。可用性也是安全屬性。」

9. **稽核**  
   「請找 `sub_`，再 grep 身分證，應該是零。資料面日誌的 subject 來自標頭，不是它自己解析 JWT。」

10. **SIEM**  
    「契約把指標名字鎖死。打開 Grafana：驗證失敗依 reason、授權拒絕依假名、正在響的告警。規則在 `infra/observability/prometheus/rules/zero-trust-gateway.yaml`。」

## 可能被問

| 問題 | 答 |
| --- | --- |
| 不開 mTLS 還算零信任？ | 算「每請求重驗」。Kind 缺的是傳輸層身分，不是「來源網段可信」。見 ADR 0003。 |
| subject 會不會撞？ | HMAC-SHA256 截 16 hex（64 bit）夠 demo 與 SOC join；正式可加長。salt 外洩見威脅模型殘餘。 |
| 為什麼不用 Istio？ | Kind + 筆電過重；也無法講 alg confusion。見 ADR 0001。 |

## 收場

回到腳本摘要的「評分對照」。補一句：威脅模型每一列都有 demo 幕次，不是事後補的 Excel。
