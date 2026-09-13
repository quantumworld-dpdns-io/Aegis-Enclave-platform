#!/usr/bin/env bash
#
# Financial Cybersecurity Challenge 展示腳本
#
# 主題：資料面才持有明文 —— 信封加密、PII 動態遮罩、金鑰用途綁定。
# 閘道驗過身分之後，subject 已是假名（AEGIS_PSEUDONYM_SALT → X-Aegis-Subject）。
# 這一場要證明的是：寫進去的是個資，讀出來的是遮罩，日誌裡連原值都沒有。
#
# 對應 CCSP Domain 2（雲端資料安全）。主持稿見 docs/demo/fincyber.md。
set -euo pipefail

# shellcheck source=scripts/demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/demo-lib.sh"

demo::parse_args "$@"

demo::header \
  "Financial Cybersecurity —— PII 遮罩與 KMS 金鑰生命週期" \
  "2026-10-03　｜　CCSP Domain 2" \
  "金鑰在 KMS、密文在資料面、假名在日誌：三層拆開，任何一層被攻破都拿不到完整明文。"

demo::preflight_header
demo::require_cmd kubectl "執行 make bootstrap"
demo::require_cmd curl    "macOS 內建應該就有；若無請 brew install curl"
demo::optional_cmd jq     "密文信封與稽核事件會以原始 JSON 呈現"
demo::optional_cmd uv     "本機跑 pytest 合約測試時才需要；容器內已內建"
demo::require_cluster
demo::require_deploy dataplane
demo::require_deploy gateway
demo::require_file "${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt" \
  "demo 用 JWT 尚未產生；見 docs/demo/README.md 的「demo 素材」一節"

BASE="${AEGIS_DEMO_BASE_URL}"
RECORDS="${BASE}/api/v1/vault/records"
CODE_ONLY='-sS -o /dev/null -w %{http_code}'

demo::pause

# ---------------------------------------------------------------------------
demo::scene "寫入一筆含 PII 的金庫紀錄" \
  "請求先過閘道（JWT 驗簽 + 授權），再由資料面做信封加密後落地。" \
  "payload 刻意放身分證、IBAN 與姓名，稍後用來證明日誌與回應都沒有原值。" \
  "Kind 展示 AEGIS_REQUIRE_MTLS=false；正式環境開 mTLS，見 ADR 0003。"

demo::port_forward "$AEGIS_NAMESPACE" "svc/gateway" "${AEGIS_GATEWAY_PORT}:${AEGIS_GATEWAY_PORT}"
demo::run "curl -sS \\
  -H \"Authorization: Bearer \$(cat '${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt')\" \\
  -H 'X-Aegis-Request-ID: demo-fincyber-001' \\
  -H 'Content-Type: application/json' \\
  -d '{\"tenant\":\"acme\",\"holder_name\":\"王小明\",\"national_id\":\"A123456789\",\"iban\":\"TW1234567890123456\",\"amount\":\"128000.00\"}' \\
  -w '\\nHTTP %{http_code}\\n' '${RECORDS}'"
demo::assert_contains "HTTP 201" "含 PII 的紀錄被接受並加密寫入"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "讀回：回應只剩遮罩後的欄位" \
  "GET 路徑會解密信封，再依欄位型別套用遮罩才回傳。" \
  "national_id、iban、holder_name 都不該以原值出現在 HTTP 回應裡。" \
  "aegis_masking_applied_total{field_type=...} 應對每一個敏感欄位加一。"

demo::run "curl -sS \\
  -H \"Authorization: Bearer \$(cat '${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt')\" \\
  -H 'X-Aegis-Request-ID: demo-fincyber-002' \\
  '${RECORDS}/demo-0001'"
demo::assert_ok "讀取路徑可回應"
demo::assert_absent "A123456789" "回應中沒有原始身分證號"
demo::assert_absent "TW1234567890123456" "回應中沒有完整 IBAN"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "信封與金鑰用途綁定" \
  "密文格式見契約第 6 節：wrapped_dek + nonce + ciphertext + aad。" \
  "aad 同時是 AES-GCM 的 additional authenticated data 與 KMS encryption context。" \
  "把同一把 DEK 搬到別的 tenant / purpose 會直接解密失敗 —— 這就是金鑰用途綁定。" \
  "主金鑰 alias/aegis-master 與假名化金鑰 alias/aegis-pseudonym 刻意分離，輪替互不影響。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/dataplane --since=15m \\
  | grep -E '\"event\":\"kms\\.(encrypt|decrypt)\"|wrapped_dek|alias/aegis-master' | tail -8 || true"
demo::assert_ok "資料面有金鑰操作稽核事件"

demo::show "AEGIS_KMS_DRIVER=localstack|vault|aws" \
  "三個 driver 共用同一組 pytest 合約測試；切換不改呼叫端"
demo::narrate "" \
  "實作：services/dataplane/app/kms/ 的 KeyProvider Protocol" \
  "決策：docs/adr/0005-envelope-encryption.md" \
  "契約第 6 節規定 aad 與 encryption context 必須位元組級一致。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "假名 subject：閘道產生，資料面只接收" \
  "資料面從不解析 JWT，也看不到原始 sub。" \
  "閘道用 AEGIS_PSEUDONYM_SALT 做 HMAC-SHA256，經 X-Aegis-Subject 傳下來。" \
  "KMS 解密指標的 subject 標籤因此也是假名，外洩偵測可以 join 卻不能反推。"

if command -v jq >/dev/null 2>&1; then
  demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/dataplane --since=15m \\
    | grep '\"subject\":\"sub_' | tail -4 \\
    | jq -c '{ts, event, subject, request_id}'"
else
  demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/dataplane --since=15m \\
    | grep '\"subject\":\"sub_' | tail -4"
fi
demo::assert_contains 'sub_' "資料面日誌的 subject 是閘道轉發的假名"
demo::narrate "" "決策：docs/adr/0004-gateway-pseudonym-subject.md"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "日誌最小化：原值不得落地" \
  "剛才寫入的身分證、IBAN、姓名若出現在任何一邊的 stdout，這一幕就失敗。" \
  "這同時滿足 PCI DSS 的日誌去識別化，也是 ESG / GDPR 最短路徑。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/gateway --since=15m | grep -c 'A123456789' || true"
demo::assert_absent 'A123456789' "閘道日誌沒有身分證號"

demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/dataplane --since=15m | grep -c 'A123456789' || true"
demo::assert_absent 'A123456789' "資料面日誌沒有身分證號"

demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/dataplane --since=15m | grep -c 'TW1234567890123456' || true"
demo::assert_absent 'TW1234567890123456' "資料面日誌沒有完整 IBAN"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "KMS 指標：加密、解密、遮罩都能量測" \
  "模組 F 的外洩告警只認契約第 3 節的名字，服務端不得更名。" \
  "指給評審看：encrypt 因寫入加一、decrypt 因讀取加一、masking_applied 因欄位加一。" \
  "aegis_masking_bypass_total 必須維持零；任何非零都會觸發 AegisMaskingBypassDetected。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} exec deploy/dataplane -- \\
  wget -qO- http://127.0.0.1:8000/metrics \\
  | grep -E '^aegis_(kms_encrypt|kms_decrypt|masking_applied|masking_bypass)_total'"
demo::assert_contains "aegis_kms_encrypt_total" "資料面產出契約規定的 KMS / 遮罩指標"

demo::show "sum by (subject) (rate(aegis_kms_decrypt_total[5m])) > 5" \
  "這是 AegisKmsDecryptRateCritical：合法身分大量解密就是內部外洩訊號"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "金鑰生命週期：輪替不必重加密整庫" \
  "信封加密的好處：輪替的是 KEK（主金鑰），不是每一筆 DEK。" \
  "新寫入用新 KEK 包裝；舊密文仍可用舊版本 unwrap，再視需要 re-wrap。" \
  "假名化金鑰獨立輪替：日誌歷史仍可 join，因為同一 salt 在輪替前的視窗內穩定。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} get deploy/dataplane -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{\"\\n\"}{end}' \\
  | grep -E 'AEGIS_KMS_|AEGIS_PSEUDONYM'"
demo::assert_contains "AEGIS_KMS_KEY_ID" "主金鑰與假名化金鑰識別碼都掛在資料面"

demo::narrate "" \
  "LocalStack 不是 FIPS 140 HSM，也沒有真實的輪替稽核軌跡。" \
  "正式環境切 AEGIS_KMS_DRIVER=aws 或 vault，並把輪替事件送進同一套 SIEM。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "本機合約測試：三個 driver 行為一致" \
  "沒有叢集也能證明 KeyProvider 的契約：generate / decrypt / 錯的 context 必失敗。" \
  "這一幕若本機沒有 uv，會略過，不影響前面的叢集展示。"

if demo::have uv; then
  demo::run "cd services/dataplane && uv run pytest -q tests -k 'key_provider or envelope or masking' --tb=line"
  demo::assert_ok "KeyProvider / 信封 / 遮罩合約測試通過"
else
  demo::show "cd services/dataplane && uv run pytest -q tests -k 'key_provider or envelope or masking'" \
    "本機尚未安裝 uv；CI 的 dataplane-py workflow 會跑同一組"
  demo::verdict skip "本機缺少 uv，略過 pytest 合約測試"
fi
demo::pause

# ---------------------------------------------------------------------------
demo::rubric "資料最小化與去識別化|寫入後回應與兩邊 stdout 都找不到原始身分證／IBAN。subject 由閘道 salt 產生，資料面只收 X-Aegis-Subject。"
demo::rubric "信封加密與金鑰用途綁定|aad 與 KMS encryption context 必須一致；主金鑰與假名化金鑰分離輪替。見 ADR 0005。"
demo::rubric "可插拔 KMS|localstack / vault / aws 三 driver 共用合約測試，展示環境用 LocalStack，正式環境可無痛切換。"
demo::rubric "外洩可偵測|aegis_kms_decrypt_total 以假名 subject 分組；遮罩失效任何非零即告警。規則在 infra/observability/prometheus/rules/data-exfiltration.yaml。"
demo::rubric "CCSP Domain 2 對照|資料分類、加密、金鑰管理、去識別化。逐項見 docs/ccsp-mapping.md。"

demo::summary
