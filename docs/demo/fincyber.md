# Financial Cybersecurity 主持稿

**時間**：2026-10-03  
**腳本**：`./scripts/demo-fincyber.sh`  
**評分主軸**：PII 遮罩、信封加密、金鑰生命週期（CCSP Domain 2）

## 開場（40 秒）

「上一場 TLN 證明誰進得來。這一場證明進來之後資料怎麼活。閘道此時已經把呼叫者變成假名，資料面連 JWT 都不看。各位會看到：寫進去的是身分證，讀出來的是遮罩，stdout 裡連原值都沒有，KMS 指標還能用同一個假名抓內部外洩。」

提醒：Kind 不開 mTLS（ADR 0003）；這一場不靠客戶端憑證。

## 分幕口條

1. **寫入含 PII**  
   「tenant acme、王小明、A123456789、IBAN。201 代表信封落地，不是明文落地。」

2. **讀回遮罩**  
   「請對螢幕做 Ctrl-F：身分證與完整 IBAN 不該出現。`aegis_masking_applied_total` 會依欄位型別加。」

3. **信封與用途綁定**  
   「契約第 6 節：`wrapped_dek`、`nonce`、`ciphertext`、`aad`。aad 同時是 GCM AAD 與 KMS encryption context。把 DEK 拿到別的 tenant 會失敗。主金鑰跟假名化金鑰分開輪替。」  
   指 ADR 0005。LocalStack 不是 HSM，正式切 aws/vault。

4. **假名只收標頭**  
   「資料面日誌的 `sub_` 是閘道用 salt 算好、從 `X-Aegis-Subject` 傳下來的。它沒有能力、也不被允許回源 token。」

5. **日誌最小化**  
   「兩邊 grep 身分證與 IBAN，預期零。這是能不能把 log 交給第三方 SOC 的最短證明。」

6. **指標**  
   「encrypt、decrypt、masking_applied。`masking_bypass` 必須是零，規則是任何非零就 critical。」  
   順手唸 `AegisKmsDecryptRateCritical`：合法帳號每秒解密超過 5 次就是外洩，不是 403。

7. **輪替**  
   「我們輪的是 KEK，不是每一筆 DEK。舊信封仍可 unwrap。展示環境的 LocalStack 沒有真實輪替軌跡，這句一定要講。」

8. **pytest 合約測試**（有 uv 才跑）  
   「三個 driver 同一組測試。沒有雲端帳號也能證明行為一致。」

## 可能被問

| 問題 | 答 |
| --- | --- |
| 為什麼不每筆都打 KMS Encrypt？ | 延遲與費用；信封把大量加解密留在本地。ADR 0005。 |
| salt 跟 KMS 假名化金鑰差在哪？ | salt：請求 who，閘道持有。KMS key：欄位 what，資料面持有。ADR 0004。 |
| 遮罩 fail-open 怎麼辦？ | 產品決策是 fail-closed；告警 `AegisMaskingBypassDetected` 與 `AegisMaskingPipelineInactive` 補盲點。 |

## 收場

打開 Grafana「資料保護」：異常解密 subject 排行、遮罩失效 stat。強調指標名字被契約鎖死，服務端改名 CI 會裂。
