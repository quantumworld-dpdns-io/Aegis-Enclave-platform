#!/usr/bin/env bash
#
# IEEE ClimateChain 展示腳本
#
# 主題：碳權不是「鏈上有數字就可信」—— 要有防雙花的退役、可重現的測試，
# 以及靜態分析進 Code Scanning。這一場刻意不依賴叢集：評審筆電沒有 Kind
# 也能把合約品質講完；有叢集時再補一幕「經閘道退役」。
#
# 對應 CCSP Domain 4（雲端應用程式安全）。主持稿見 docs/demo/climatechain.md。
set -euo pipefail

# shellcheck source=scripts/demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/demo-lib.sh"

demo::parse_args "$@"

demo::header \
  "IEEE ClimateChain —— 碳權合約測試與靜態分析" \
  "2026-10-05　｜　CCSP Domain 4" \
  "ERC-1155 批次碳權 + 退役登記：單元、模糊、不變量測試與 Slither，先證明合約自己站得住。"

demo::preflight_header
demo::require_cmd forge  "執行 make bootstrap，並確認 ~/.foundry/bin 在 PATH"
demo::optional_cmd docker "Slither 走官方 eth-security-toolbox 映像"
demo::optional_cmd kubectl "有叢集才演示「經閘道退役」；沒有不影響前半段"
demo::require_file "${DEMO_REPO_ROOT}/contracts/foundry.toml" \
  "找不到 Foundry 設定；確認工作目錄是 repo 根"

# 合約展示不把「沒叢集」當致命傷。有 kubectl 且叢集通才加後段。
if [ "$DEMO_MODE" = 'live' ] && demo::have kubectl && kubectl cluster-info >/dev/null 2>&1; then
  demo::require_cluster
  demo::require_file "${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt" \
    "若要演示 API 退役，需要 demo JWT；見 docs/demo/README.md"
else
  demo::info "未偵測到可用叢集，後段「經閘道退役」會略過（合約測試仍完整跑）"
fi

demo::pause

# ---------------------------------------------------------------------------
demo::scene "合約介面：鑄造、退役、防雙花" \
  "CarbonCredit 是 ERC-1155：同一個合約用 projectId 區分不同專案的碳權。" \
  "retire 會銷毀代幣並在 RetirementRegistry 留下不可覆寫的紀錄。" \
  "同一批已退役量不能再被轉出或再次退役 —— 這是雙花防護的業務含義。"

demo::run "sed -n '1,80p' contracts/src/CarbonCredit.sol 2>/dev/null || ls contracts/src"
demo::assert_ok "讀得到合約原始檔（或至少列得出 src/）"

demo::narrate "" \
  "對外 ABI 鎖在 docs/CONTRACT.md 第 7 節：mintBatch / retire / totalRetired，" \
  "以及 CreditsMinted、CreditsRetired 兩個事件。dataplane 靠事件對帳，不掃整條鏈。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "單元測試：先證明快樂路徑與權限" \
  "forge test 會跑 contracts/test/ 裡的單元案例。" \
  "deny_warnings=true，編譯警告直接當失敗，避免『沒人理的小問題』混進評審機器。"

demo::run "cd contracts && forge test -vv --no-match-contract Invariant"
demo::assert_ok "Foundry 單元測試通過（略過耗時的 invariant 套件，下一幕再跑）"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "模糊測試與不變量：隨機輸入也守住退役不變量" \
  "fuzz.runs 預設 512；invariant 深度 64，且 fail_on_revert=true ——" \
  "handler 已把輸入 bound 在合法區間，任何 revert 都代表缺陷。" \
  "CI profile 會把 fuzz 拉到 10_000、invariant 1024，現場用預設以免超時。"

demo::run "cd contracts && forge test -vv --match-contract Invariant"
demo::assert_ok "不變量測試守住退役／餘額不變量"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "覆蓋率：不是 100% 才算，但關鍵路徑必須被踩到" \
  "coverage profile 關掉 optimizer，行號才對得上原始碼。" \
  "評審要看的是 retire / mintBatch / 權限修飾子被覆蓋，不是整份 lcov 的小數點。"

demo::run "cd contracts && forge coverage --report summary"
demo::assert_ok "產出 Solidity 覆蓋率摘要"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "Slither：靜態分析進 Code Scanning" \
  "本機不裝 Python 版 Slither，改跑 trailofbits/eth-security-toolbox，" \
  "版本與 CI 的 crytic/slither-action 對齊，避免『我筆電掃不到、CI 才爆』。" \
  "高置信重入、任意寫入、未檢查回傳值，都應在這裡現形。"

if demo::have docker; then
  demo::run "docker run --rm -v \"${DEMO_REPO_ROOT}/contracts:/src\" trailofbits/eth-security-toolbox:latest \\
    slither /src --config-file /src/slither.config.json"
  demo::assert_ok "Slither 靜態分析跑完"
else
  demo::show "make scan-contracts" \
    "本機沒有 Docker；CI 會把 SARIF 上傳 GitHub Code Scanning"
  demo::verdict skip "本機沒有 Docker，略過 Slither"
fi
demo::pause

# ---------------------------------------------------------------------------
demo::scene "部署產出：位址寫進契約規定的 JSON" \
  "forge script 部署後必須寫 contracts/deployments/local.json：" \
  "{\"chainId\":31337,\"CarbonCredit\":\"0x...\",\"RetirementRegistry\":\"0x...\"}" \
  "資料面的 AEGIS_CARBON_CONTRACT_ADDR 由此回填，禁止手抄進清單。"

demo::run "ls -la contracts/deployments 2>/dev/null || true; cat contracts/deployments/local.json 2>/dev/null || echo '尚未部署（本機 anvil / make up 之後才會有）'"
if [ "$DEMO_MODE" = 'live' ] && [ -f contracts/deployments/local.json ]; then
  demo::assert_contains "CarbonCredit" "部署產出含 CarbonCredit 位址"
else
  demo::verdict skip "尚未產生 local.json（沒有跑部署不影響測試幕）"
fi
demo::pause

# ---------------------------------------------------------------------------
demo::scene "可選：經閘道觸發退役（應用層到鏈上）" \
  "有叢集時才跑。analyst 身分依政策應拿 403 —— 退役是高價值操作，最小權限。" \
  "這同時把 ClimateChain 接到 TLN 的授權故事：合約對，閘道也要對。" \
  "Kind 展示關閉 mTLS；正式環境開 mTLS（ADR 0003）。"

if [ "$DEMO_MODE" = 'live' ] && demo::have kubectl && kubectl cluster-info >/dev/null 2>&1 \
   && [ -f "${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt" ]; then
  demo::port_forward "$AEGIS_NAMESPACE" "svc/gateway" "${AEGIS_GATEWAY_PORT}:${AEGIS_GATEWAY_PORT}"
  demo::run "curl -sS -o /dev/null -w '%{http_code}' \\
    -H \"Authorization: Bearer \$(cat '${AEGIS_DEMO_TOKEN_DIR}/analyst.jwt')\" \\
    -H 'Content-Type: application/json' -d '{\"projectId\":1,\"amount\":10}' \\
    '${AEGIS_DEMO_BASE_URL}/api/v1/carbon/retire'"
  demo::assert_http 403 "analyst 越權退役被閘道拒絕（合約再正確也進不去）"
else
  demo::show "curl -H \"Authorization: Bearer \$(cat .demo/tokens/analyst.jwt)\" -d '{\"projectId\":1,\"amount\":10}' ${AEGIS_DEMO_BASE_URL}/api/v1/carbon/retire" \
    "沒有叢集或 JWT，這一幕只展示指令"
  demo::verdict skip "略過經閘道退役（前置不足）"
fi
demo::pause

# ---------------------------------------------------------------------------
demo::rubric "智能合約正確性|單元 + fuzz + invariant 覆蓋鑄造／退役／防雙花。fail_on_revert 讓隨機輸入的 revert 直接當缺陷。"
demo::rubric "靜態分析進 SDLC|Slither 以容器執行、CI 上傳 SARIF，不靠本機 Python 環境。第 5 幕可現場重跑。"
demo::rubric "介面契約|ABI 與 deployments/local.json 格式鎖在 CONTRACT.md 第 7 節，資料面對帳只認事件。"
demo::rubric "應用層最小權限|就算合約對，analyst 也不能退役。零信任閘道是合約的第一道門，不是可選配件。"
demo::rubric "CCSP Domain 4 對照|安全 SDLC、程式碼審查、相依與靜態分析。逐項見 docs/ccsp-mapping.md。"

demo::summary
