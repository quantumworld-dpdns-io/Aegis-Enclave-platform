#!/usr/bin/env bash
#
# TLN Hackathon（2026-09-19～20）展示腳本
#
# 主題：零信任 API 閘道 —— 每一次請求都重新驗證，攔截後留下可稽核的證據。
# Kind 展示環境關閉 mTLS（AEGIS_REQUIRE_MTLS=false，見 ADR 0003），
# 因此本腳本把火力集中在「無效 JWT」與「演算法混淆」兩類可重現的驗證攻擊，
# 並用旁白對照正式環境必須開啟的傳輸層身分。
#
# 對應 CCSP Domain 5（雲端安全維運）。主持稿見 docs/demo/tln.md。
set -euo pipefail

# shellcheck source=scripts/demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/demo-lib.sh"

demo::parse_args "$@"

demo::header \
  "TLN Hackathon —— 零信任 API 閘道" \
  "2026-09-19 ～ 2026-09-20　｜　CCSP Domain 5" \
  "沒有「內網所以可信」這回事：每一次請求都重新證明身分、權限與額度。"

# ---------------------------------------------------------------------------
# 前置條件
# ---------------------------------------------------------------------------
demo::preflight_header
demo::require_cmd kubectl "執行 make bootstrap"
demo::require_cmd curl    "macOS 內建應該就有；若無請 brew install curl"
demo::optional_cmd jq     "稽核日誌會以原始 JSON 單行呈現，較難閱讀"
demo::require_cluster
demo::require_deploy gateway
demo::require_deploy dataplane
demo::require_file "${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt" \
  "demo 用 JWT 尚未產生；見 docs/demo/README.md 的「demo 素材」一節"
demo::require_file "${AEGIS_DEMO_TOKEN_DIR}/attack-alg-none.jwt" \
  "缺少 alg=none 攻擊 token；見 docs/demo/README.md"
demo::require_file "${AEGIS_DEMO_TOKEN_DIR}/attack-alg-hs256.jwt" \
  "缺少 RS256→HS256 攻擊 token；見 docs/demo/README.md"

BASE="${AEGIS_DEMO_BASE_URL}"
RECORDS="${BASE}/api/v1/vault/records"
CODE_ONLY='-sS -o /dev/null -w %{http_code}'

demo::pause

# ---------------------------------------------------------------------------
demo::scene "健康探針：唯一不需要驗證的路徑" \
  "零信任不等於「什麼都要驗證」，而是「例外必須是刻意設計的」。" \
  "/healthz 與 /readyz 給 kubelet 用，刻意豁免驗證，其他全部收緊。" \
  "先讓這一發成功，證明後面的失敗是被擋下來，不是服務掛了。"

demo::port_forward "$AEGIS_NAMESPACE" "svc/gateway" "${AEGIS_GATEWAY_PORT}:${AEGIS_GATEWAY_PORT}"
demo::run "curl ${CODE_ONLY} '${BASE}/healthz'"
demo::assert_http 200 "存活探針可在無 token 的情況下回應"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "仲裁說明：Kind 展示關閉 mTLS，正式環境必須開啟" \
  "infra/k8s/base/gateway.yaml 把 AEGIS_REQUIRE_MTLS 設為 false。" \
  "Kind 叢集沒有 Ingress、沒有 cert-manager、沒有 service mesh，" \
  "契約上的 8080 是明文 HTTP 埠；若在這裡強制用戶端憑證，所有展示流量都會在 TLS 交握失敗。" \
  "關掉的只是傳輸層身分。JWT 驗簽、Rego 授權、限流仍然全程啟用。" \
  "正式環境務必改回 true，由 Ingress 或 sidecar 轉發用戶端憑證。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} get deploy/gateway -o jsonpath='{.spec.template.spec.containers[0].env}' \\
  | tr ',' '\\n' | grep -E 'AEGIS_REQUIRE_MTLS|AEGIS_PSEUDONYM_SALT' || true"
demo::assert_contains "AEGIS_REQUIRE_MTLS" "閘道部署列得出 mTLS 開關（Kind 值為 false）"

demo::show "curl --cert client.crt --key client.key --cacert ca.crt https://gateway.example/api/v1/vault/records" \
  "正式環境的呼叫型態：TLS 交握就先驗用戶端憑證，應用層才輪到 JWT"
demo::narrate "" \
  "決策紀錄：docs/adr/0003-kind-demo-mtls.md" \
  "本場 TLN 能在評審筆電上重現的攻擊面，是無效 JWT 與演算法混淆，不是 mTLS 交握失敗。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "攻擊一：token 是偽造的" \
  "沒有 mTLS 並不代表「沒帶 token 也能進來」。" \
  "閘道用 AEGIS_JWKS_PATH 的公鑰驗簽，簽章不符一律 401。" \
  "同時觀察 aegis_authn_failures_total{reason=\"invalid_signature\"} 有沒有加一。"

demo::run "curl ${CODE_ONLY} \\
  -H 'Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJhdHRhY2tlciJ9.bm90LWEtc2lnbmF0dXJl' \\
  '${RECORDS}/demo-0001'"
demo::assert_http 401 "簽章無效的 JWT 被拒絕"

demo::run "curl ${CODE_ONLY} '${RECORDS}/demo-0001'"
demo::assert_http 401 "完全不帶 token 的請求被拒絕（reason=missing_token）"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "攻擊二：演算法混淆（algorithm confusion）" \
  "這是 JWT 最經典的實作漏洞，也是最能看出實作者功力的一題。" \
  "手法一：把 header 改成 alg=none，賭驗證端「沒有簽章就不驗簽章」。" \
  "手法二：把 alg 從 RS256 改成 HS256，用 JWKS 裡的 RSA 公鑰當 HMAC 密鑰 ——" \
  "公鑰是公開的，若驗證端照 header 說的做，攻擊者就能自簽任意身分。" \
  "正確做法是把允許的演算法寫死在伺服器端，不信任 header 的 alg 欄位。"

demo::run "curl ${CODE_ONLY} \\
  -H \"Authorization: Bearer \$(cat '${AEGIS_DEMO_TOKEN_DIR}/attack-alg-none.jwt')\" \\
  '${RECORDS}/demo-0001'"
demo::assert_http 401 "alg=none 的 token 被拒絕"

demo::run "curl ${CODE_ONLY} \\
  -H \"Authorization: Bearer \$(cat '${AEGIS_DEMO_TOKEN_DIR}/attack-alg-hs256.jwt')\" \\
  '${RECORDS}/demo-0001'"
demo::assert_http 401 "RS256→HS256 混淆攻擊被拒絕（伺服器端寫死允許的演算法）"

demo::narrate "" "實作位置：services/gateway/internal/middleware/authn.go" \
  "對應單元測試：同目錄 authn_test.go 的 TestRejectAlgConfusion。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "合法請求：驗證通過，閘道產生假名 subject" \
  "同一條 middleware 鏈，換成合法 token 就順利通行。" \
  "順序是 JWT/SBT 驗簽 → 授權決策 → 限流 → OTel 追蹤注入。" \
  "subject 不來自客戶端、也不由資料面重算：閘道用 AEGIS_PSEUDONYM_SALT" \
  "對 JWT 的 sub 做 HMAC-SHA256，取前 16 碼十六進位，加上 sub_ 前綴，" \
  "再以 X-Aegis-Subject 傳給 dataplane。日誌與指標只看得到這個假名。" \
  "X-Aegis-Request-ID 會被一路帶到 dataplane，稍後在日誌裡就靠它串起來。"

demo::run "curl -sS \\
  -H \"Authorization: Bearer \$(cat '${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt')\" \\
  -H 'X-Aegis-Request-ID: demo-tln-001' \\
  -H 'Content-Type: application/json' \\
  -d '{\"tenant\":\"acme\",\"holder_name\":\"王小明\",\"national_id\":\"A123456789\",\"iban\":\"TW1234567890123456\",\"amount\":\"128000.00\"}' \\
  -w '\\nHTTP %{http_code}\\n' '${RECORDS}'"
demo::assert_contains "HTTP 201" "合法請求成功建立加密紀錄"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "攻擊三：越權（有效身分，但超出授權範圍）" \
  "這是零信任跟「有帳號就通行」最大的差別：驗證通過只是入場，不是通行證。" \
  "analyst 這個身分只能讀寫 vault 紀錄，不能觸發碳權退役 ——" \
  "授權決策由 Rego 政策做，回 403 並累加 aegis_authz_denied_total。" \
  "注意這個指標的 subject 標籤是閘道算出的假名，不是原始使用者識別資料。"

demo::run "curl ${CODE_ONLY} \\
  -H \"Authorization: Bearer \$(cat '${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt')\" \\
  -H 'Content-Type: application/json' -d '{\"projectId\":1,\"amount\":10}' \\
  '${BASE}/api/v1/carbon/retire'"
demo::assert_http 403 "analyst 身分越權呼叫碳權退役被授權層拒絕"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "縱深防禦：網路層的第二道鎖（Cilium L7）" \
  "假設攻擊者拿下了閘道 Pod，他還是打不到 dataplane 不該被打的路徑。" \
  "契約只放行 /internal/v1/* 與 /internal/healthz；其餘一律拒絕。" \
  "這裡用 ephemeral container 塞進 gateway 的 Pod —— 同一個 Pod 就是" \
  "同一個 Cilium 身分，所以這次真的是「用閘道的身分」去打不該打的路徑。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} debug \\
  \"\$(kubectl -n ${AEGIS_NAMESPACE} get pod -l app.kubernetes.io/name=gateway -o jsonpath='{.items[0].metadata.name}')\" \\
  -q --image=curlimages/curl:8.11.1 -- \\
  curl -sS -m 8 -o /dev/null -w '%{http_code}' \\
  http://dataplane.${AEGIS_NAMESPACE}.svc.cluster.local:8000/internal/v1/keys"
demo::assert_http 403 "未列入白名單的 /internal/v1/keys 被 Cilium L7 策略攔下"

demo::narrate "" "L7 策略是 HTTP 感知的，所以它回的是 403 而不是把封包默默丟掉；" \
  "L3/L4 層的越權（例如攻擊者 Pod 直連）才會是 DROPPED，那一幕留給 HackTitan。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "限流：可用性也是安全屬性" \
  "AEGIS_RATE_LIMIT_RPS=20、burst=40，以假名 subject 為單位而非以 IP 為單位 ——" \
  "因為在 NAT 或 service mesh 後面，IP 幾乎沒有識別意義。" \
  "連打 60 發，前 40 發吃掉 burst，之後開始出現 429。"

demo::run "for i in \$(seq 1 60); do \\
  curl -sS -o /dev/null -w '%{http_code}\\n' \\
    -H \"Authorization: Bearer \$(cat '${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt')\" \\
    '${RECORDS}/demo-0001'; \\
done | sort | uniq -c"
demo::assert_contains "429" "超出額度的請求被限流（aegis_ratelimit_throttled_total 上升）"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "稽核軌跡：攔截之後留下了什麼" \
  "偵測不到的防禦等於沒有防禦。攻擊都在 stdout 留下結構化 JSON 事件。" \
  "subject 由閘道的 AEGIS_PSEUDONYM_SALT 產生，經 X-Aegis-Subject 傳給資料面。" \
  "同一個人永遠對應同一個假名，所以事件仍可 join 分析；但無法反推原值。" \
  "日誌裡不會有原始 PII、金鑰材料，也不會有完整 JWT。"

if command -v jq >/dev/null 2>&1; then
  demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/gateway --since=10m \\
    | grep '\"event\":\"authz.decision\"' | tail -6 \\
    | jq -c '{ts, event, subject, resource, decision, reason}'"
else
  demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/gateway --since=10m \\
    | grep '\"event\":\"authz.decision\"' | tail -6"
fi
demo::assert_contains 'sub_' "稽核事件的 subject 是假名而非真實身分"

demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/gateway --since=10m | grep -c 'A123456789' || true"
demo::assert_absent 'A123456789' "剛才送進去的身分證號完全沒有出現在閘道日誌中"

demo::run "kubectl -n ${AEGIS_NAMESPACE} logs deploy/dataplane --since=10m \\
  | grep -E 'X-Aegis-Subject|\"subject\":\"sub_' | tail -4 || true"
demo::assert_contains 'sub_' "資料面日誌的 subject 來自閘道轉發的 X-Aegis-Subject"

demo::narrate "" \
  "假名化實作：services/gateway（HMAC 金鑰來自 AEGIS_PSEUDONYM_SALT）" \
  "傳遞標頭：X-Aegis-Subject；決策紀錄：docs/adr/0004-gateway-pseudonym-subject.md" \
  "日誌欄位契約：docs/CONTRACT.md 第 4 節。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "SIEM：把這些事件變成會叫的告警" \
  "指標名稱由 docs/CONTRACT.md 第 3 節固定，儀表板與告警只依賴這些名字。" \
  "先看原始計數器確實在動，再打開 Grafana 看它變成什麼樣的畫面。"

demo::port_forward "$AEGIS_NAMESPACE" "svc/gateway" "${AEGIS_GATEWAY_METRICS_PORT}:${AEGIS_GATEWAY_METRICS_PORT}"
demo::run "curl -sS 'http://127.0.0.1:${AEGIS_GATEWAY_METRICS_PORT}/metrics' \\
  | grep -E '^aegis_(authn_failures|authz_denied|ratelimit_throttled)_total'"
demo::assert_contains "aegis_authn_failures_total" "三個安全事件計數器都有值"

demo::show "kubectl -n ${AEGIS_OBS_NAMESPACE} port-forward svc/kube-prometheus-stack-grafana 3000:80" \
  "現場改用另一個終端機開著，方便切到瀏覽器"
demo::narrate "" \
  "瀏覽器打開 http://localhost:3000 → Dashboards → Aegis Zero-Trust SIEM。" \
  "預設帳密見 docs/demo/README.md（只適用本機 Kind，正式環境不可沿用）。" \
  "要指給評審看的三個面板：" \
  "  1. 驗證失敗依 reason 分佈 —— 剛才偽造 JWT 與 alg confusion 各自對應哪一根柱子" \
  "  2. 授權拒絕熱點依假名 subject 排名 —— 誰在試探不屬於他的資源" \
  "  3. 觸發中的告警 —— 例如 15 分鐘內驗證失敗暴增" \
  "告警規則：infra/observability/prometheus/rules/，儀表板 JSON 在同目錄的 grafana/。"
demo::pause

# ---------------------------------------------------------------------------
demo::rubric "零信任架構落實|Kind 展示關閉 mTLS 是為了能在筆電上重現，不是省略傳輸層身分。正式環境開 mTLS；本場以 JWT 驗簽、演算法混淆防護、Rego 授權、限流與 Cilium L7 證明「每一層獨立驗證」。"
demo::rubric "威脅建模|docs/threat-model.md 用 STRIDE 逐一分析每條資料流。第 3、4 幕對應偽造憑證與演算法混淆；第 6 幕對應權限提升；第 7 幕對應橫向移動。"
demo::rubric "自動化威脅攔截|攔截由 middleware 與 CiliumNetworkPolicy 在請求路徑上同步完成，不是事後掃描。第 8 幕的 429 與第 6 幕的 403 都是即時判定。"
demo::rubric "日誌審計與 SIEM|結構化 JSON 稽核事件（契約第 4 節）→ Prometheus 指標（契約第 3 節）→ Grafana 告警。subject 由閘道 AEGIS_PSEUDONYM_SALT 產生並經 X-Aegis-Subject 傳遞。"
demo::rubric "CCSP Domain 5 對照|事件偵測與回應、日誌留存與完整性、安全維運指標。逐項對照見 docs/ccsp-mapping.md。"

demo::summary
