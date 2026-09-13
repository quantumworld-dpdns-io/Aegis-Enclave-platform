# ADR 0005：信封加密與可插拔 KeyProvider

- 狀態：已採納
- 日期：2026-09-13
- 決策者：架構仲裁
- 參照：`docs/CONTRACT.md` 第 5、6 節；`services/dataplane`

## 背景

FinCyber 與 CCSP Domain 2 要求：靜態資料加密、金鑰用途綁定、以及可證明的金鑰生命週期。若每一筆金庫紀錄都同步打一次雲端 KMS 做加解密，展示環境會又慢又貴，正式環境也會把 KMS 變成可用性單點。

若把 AES 金鑰寫死在應用設定裡，又失去輪替、用途綁定與稽核。

另外，評審機器不能假設有 AWS 帳號或已解封的 Vault。

## 決策

資料面只經 `KeyProvider` Protocol 碰金鑰材料：

```
generate_data_key(ctx) → DEK + wrapped_dek
decrypt_data_key(wrapped, ctx) → DEK
rotate(key_id) → new_key_id
```

- 資料本體用 AES-256-GCM 在本地加密；落地的是密文加上 **被 KEK 包起來的 DEK**。
- `aad` 同時作為 GCM additional authenticated data 與 KMS encryption context，欄位為 `record_id` / `tenant` / `purpose`。兩者必須位元組級一致，否則 unwrap 失敗。
- 三個 driver：`localstack`（Kind 預設）、`vault`、`aws`。以 `AEGIS_KMS_DRIVER` 切換，共用同一組 pytest 合約測試。
- 主金鑰 `alias/aegis-master` 與欄位假名化金鑰 `alias/aegis-pseudonym` 分離（請求主體假名見 ADR 0004，不走這把 KMS 金鑰）。
- LocalStack **不是** 生產 KMS：無 FIPS 140、無真實輪替軌跡。文件與 demo 旁白必須講明，正式環境切 `aws` 或 `vault`。

## 後果

- 輪替 KEK 不必重加密整庫；舊信封用舊版本 unwrap，新寫入用新 KEK。
- 把 DEK 搬到別的 tenant / purpose 會失敗，這是 Domain 2「金鑰用途綁定」的可執行證明。
- 多一個抽象層。禁止在 handler 裡直接呼叫 boto3 / hvac，以免契約測試形同虛設。
- 密文信封 JSON schema 鎖在契約第 6 節，模組 F 不得依賴未列名的欄位。

## 替代方案

- **全程 KMS Encrypt**：簡單，但每筆打 KMS，demo 與費用都不可接受。
- **應用內建靜態 AES key**：無法展示用途綁定與輪替，否決。
- **只支援 AWS**：評審與離線 demo 直接做不了。
