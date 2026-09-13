# 模組 C：資料面（dataplane）

Python + FastAPI 資料安全服務。閘道管「誰可以進來」，這裡管「資料怎麼被保護」。

## 職責

- 信封加密：KMS 產 DEK，本機 AES-256-GCM 加密，只落地 wrapped DEK。格式見 `docs/CONTRACT.md` 第 6 節。
- PII 動態遮罩：依 `X-Aegis-Role` 決定強度。
- 碳權退役：`web3` 呼叫 `CarbonCredit.retire`；`contracts/deployments/local.json` 不存在時回 503，不崩潰。

## 路由（只開這些）

- `GET /internal/healthz`
- `POST /internal/v1/records`
- `GET /internal/v1/records/{id}`
- `POST /internal/v1/chain/retire`
- `GET /metrics`

`/docs` 與 `/openapi.json` 關閉，避免 Cilium L7 demo 以外的攻擊面。

## 標頭契約

資料面**信任**閘道傳來的標頭，不再對 subject 做第二次 HMAC：

| 標頭 | 用途 |
| --- | --- |
| `X-Aegis-Request-ID` | 分散式追蹤 |
| `X-Aegis-Subject` | 已假名化的 subject，直接進日誌與 `aegis_kms_decrypt_total` |
| `X-Aegis-Role` | `vault_admin` 明文、`vault_reader` 部分遮罩、其餘全遮（tokenization） |

`AEGIS_PSEUDONYM_SALT_KEY_ID` 只拿來對 PII 欄位做決定論 HMAC，與 subject 假名分開。

## 切換 KeyProvider

```bash
export AEGIS_KMS_DRIVER=localstack   # 預設，打 LocalStack
export AEGIS_KMS_DRIVER=vault        # HashiCorp Vault Transit
export AEGIS_KMS_DRIVER=aws          # 真實 AWS KMS
```

三個 driver 共用 `tests/test_kms_contract.py`。測試用 moto 模擬 AWS/LocalStack，Vault 用 in-memory fake，不依賴外部服務。

## 本機驗證

```bash
uv sync
uv run ruff check app tests
uv run mypy app
uv run pytest -v --cov=app
docker build -t aegis/dataplane:dev .
```

映像以 uid 10002 非 root 執行，對齊 `infra/k8s/base/dataplane.yaml`。
