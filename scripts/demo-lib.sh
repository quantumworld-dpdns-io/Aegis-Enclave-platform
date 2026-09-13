#!/usr/bin/env bash
#
# scripts/demo-lib.sh —— 五支賽事展示腳本的共用骨架
#
# 這支檔案不是 demo 本身。它被 scripts/demo-<賽事>.sh 以 source 載入，
# 提供分幕、旁白、指令執行、判定與摘要的統一輸出格式。
# 直接執行它只會印出說明並以 0 結束，這樣 CI 若用
# `for f in scripts/demo-*.sh; do bash "$f" --dry-run; done` 掃過去也不會失敗。
#
# 三個設計原則：
#
#   1. 現場 demo 最怕黑畫面。任何一幕的指令失敗都不會讓腳本崩潰 ——
#      結束碼被捕捉成「判定結果」而非致命錯誤，腳本一定會走到摘要那一幕。
#   2. 沒有叢集也要能跑完。--dry-run 只印指令；未加 --dry-run 但前置條件
#      不足時會自動降級（degraded），把後續指令改為只印不跑並標記「略過」。
#   3. 輸出是給人看的。每一幕都是「要證明什麼 → 指令 → 實際輸出 → 判定」。
#
# 相容性：本機 /usr/bin/env bash 解析到 macOS 內建的 bash 3.2，
# 因此全檔避免 associative array、mapfile、${var,,} 等 bash 4+ 語法。

# ---------------------------------------------------------------------------
# 路徑
# ---------------------------------------------------------------------------
DEMO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_REPO_ROOT="$(cd "${DEMO_LIB_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# 顏色（非終端機或設了 NO_COLOR 時自動停用，方便寫進 CI log 或轉存檔案）
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_MAGENTA=$'\033[0;35m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''
  C_BLUE=''; C_CYAN=''; C_MAGENTA=''
fi

readonly DEMO_RULE='──────────────────────────────────────────────────────────────────────────'

# ---------------------------------------------------------------------------
# 全域狀態
# ---------------------------------------------------------------------------
DEMO_NAME=''            # 賽事名稱
DEMO_DATE=''            # 賽事日期
DEMO_TAGLINE=''         # 一句話主題
DEMO_MODE='live'        # live | dry | degraded
DEMO_INTERACTIVE='false'
DEMO_STATUS=0           # 最近一次 demo::run 的結束碼
DEMO_OUTPUT=''          # 最近一次 demo::run 的輸出
DEMO_SCENE_NO=0
DEMO_PASS=0
DEMO_FAIL=0
DEMO_SKIP=0
DEMO_MAX_LINES="${DEMO_MAX_LINES:-20}"   # 每個指令最多顯示幾行輸出
DEMO_VERDICTS=()
DEMO_RUBRIC=()
DEMO_BLOCKERS=()
DEMO_PF_PIDS=()

# 各腳本共用的可覆寫端點設定。預設值全部對齊 docs/CONTRACT.md。
AEGIS_NAMESPACE="${AEGIS_NAMESPACE:-aegis}"
AEGIS_OBS_NAMESPACE="${AEGIS_OBS_NAMESPACE:-observability}"
AEGIS_ATTACKER_NAMESPACE="${AEGIS_ATTACKER_NAMESPACE:-attacker}"
AEGIS_CLUSTER_NAME="${AEGIS_CLUSTER_NAME:-aegis-enclave}"
AEGIS_GATEWAY_PORT="${AEGIS_GATEWAY_PORT:-8080}"
AEGIS_GATEWAY_METRICS_PORT="${AEGIS_GATEWAY_METRICS_PORT:-9090}"
AEGIS_DEMO_BASE_URL="${AEGIS_DEMO_BASE_URL:-https://127.0.0.1:${AEGIS_GATEWAY_PORT}}"
# demo 用的用戶端憑證與 JWT。實際產生者見 docs/demo/README.md 的「介面缺口」一節。
AEGIS_DEMO_ASSET_DIR="${AEGIS_DEMO_ASSET_DIR:-${DEMO_REPO_ROOT}/.demo}"
AEGIS_DEMO_PKI_DIR="${AEGIS_DEMO_PKI_DIR:-${AEGIS_DEMO_ASSET_DIR}/pki}"
AEGIS_DEMO_TOKEN_DIR="${AEGIS_DEMO_TOKEN_DIR:-${AEGIS_DEMO_ASSET_DIR}/tokens}"

# ---------------------------------------------------------------------------
# 基本輸出
# ---------------------------------------------------------------------------
demo::_line() { printf '%s\n' "$*"; }

demo::info()  { printf '%s\n' "  ${C_CYAN}·${C_RESET} $*"; }
demo::warn()  { printf '%s\n' "  ${C_YELLOW}!${C_RESET} $*"; }
demo::error() { printf '%s\n' "  ${C_RED}x${C_RESET} $*" >&2; }

# 旁白：這一幕在講什麼。刻意用縮排與顏色跟指令輸出區隔開。
demo::narrate() {
  local text
  for text in "$@"; do
    printf '%s\n' "    ${C_DIM}${text}${C_RESET}"
  done
}

# ---------------------------------------------------------------------------
# 參數解析
# ---------------------------------------------------------------------------
demo::usage() {
  cat <<EOF
用法： $(basename "${BASH_SOURCE[1]:-demo.sh}") [選項]

選項：
  --dry-run       只印出每一幕會執行的指令，不真的執行。
                  沒有叢集時的預演模式，也是 CI 檢查腳本可執行性的方式。
  --interactive   每一幕結束後暫停，等你按 Enter 才繼續，方便現場口頭講解。
  --max-lines N   每個指令最多顯示 N 行輸出（預設 ${DEMO_MAX_LINES}）。
  -h, --help      顯示這段說明。

環境變數（預設值對齊 docs/CONTRACT.md）：
  AEGIS_NAMESPACE          應用命名空間（預設 aegis）
  AEGIS_DEMO_BASE_URL      閘道對外位址（預設 https://127.0.0.1:8080）
  AEGIS_DEMO_ASSET_DIR     demo 用 PKI 與 JWT 的存放目錄（預設 <repo>/.demo）
  NO_COLOR                 設任何值即停用顏色
EOF
}

demo::parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)     DEMO_MODE='dry' ;;
      --interactive) DEMO_INTERACTIVE='true' ;;
      --max-lines)
        shift
        if [ "$#" -eq 0 ]; then
          demo::error "--max-lines 需要一個數字參數"
          return 2
        fi
        DEMO_MAX_LINES="$1"
        ;;
      -h|--help)     demo::usage; exit 0 ;;
      *)
        demo::error "未知參數：$1"
        demo::usage >&2
        return 2
        ;;
    esac
    shift
  done
  return 0
}

# ---------------------------------------------------------------------------
# 模式切換
# ---------------------------------------------------------------------------
# 前置條件不足時降級：指令改為只印不跑，判定標記為「略過」。
# 刻意不做 exit —— 讓觀眾仍然看得到完整的分幕結構與每一幕的意圖。
demo::degrade() {
  if [ "$DEMO_MODE" = 'live' ]; then
    DEMO_MODE='degraded'
  fi
}

demo::is_executing() { [ "$DEMO_MODE" = 'live' ]; }

demo::mode_label() {
  case "$DEMO_MODE" in
    dry)      printf '%s' "${C_YELLOW}預演模式 (--dry-run)${C_RESET}" ;;
    degraded) printf '%s' "${C_YELLOW}降級模式（前置條件不足，只印指令）${C_RESET}" ;;
    *)        printf '%s' "${C_GREEN}實際執行${C_RESET}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 前置條件檢查
# ---------------------------------------------------------------------------
demo::blocker() {
  # $1 = 問題描述, $2 = 修復建議
  DEMO_BLOCKERS+=("$1|$2")
  printf '%s\n' "  ${C_YELLOW}缺少${C_RESET} $1"
  printf '%s\n' "        ${C_DIM}修復：$2${C_RESET}"
}

# 所有 demo::require_* 一律 return 0。
# 它們是「檢查並降級」而不是「檢查並中止」，若回傳非零，呼叫端在 set -e 之下
# 會在前置檢查階段就整支結束 —— 那正好是我們最不想要的行為。
# 需要分支時請改用 demo::have 或 demo::is_executing。
demo::have() { command -v "$1" >/dev/null 2>&1; }

# 必要指令：缺少就降級（但不中止）。
demo::require_cmd() {
  local cmd="$1" hint="$2"
  if demo::have "$cmd"; then
    printf '%s\n' "  ${C_GREEN}OK${C_RESET}    ${cmd}"
    return 0
  fi
  demo::blocker "指令 ${cmd} 未安裝" "$hint"
  demo::degrade
  return 0
}

# 選用指令：缺少只提醒，該幕會退化成較陽春的展示。
demo::optional_cmd() {
  local cmd="$1" note="$2"
  if demo::have "$cmd"; then
    printf '%s\n' "  ${C_GREEN}OK${C_RESET}    ${cmd}"
  else
    printf '%s\n' "  ${C_DIM}選用${C_RESET}  ${cmd} 缺少 —— ${note}"
  fi
  return 0
}

demo::require_file() {
  local path="$1" hint="$2"
  if [ -e "$path" ]; then
    printf '%s\n' "  ${C_GREEN}OK${C_RESET}    ${path#"${DEMO_REPO_ROOT}"/}"
    return 0
  fi
  demo::blocker "找不到 ${path#"${DEMO_REPO_ROOT}"/}" "$hint"
  demo::degrade
  return 0
}

# 叢集連通性。這是 demo-tln / fincyber / forgehacks / hacktitan 的共同前提。
demo::require_cluster() {
  if [ "$DEMO_MODE" = 'dry' ]; then
    printf '%s\n' "  ${C_DIM}略過${C_RESET}  叢集檢查（--dry-run）"
    return 0
  fi
  command -v kubectl >/dev/null 2>&1 || {
    demo::blocker "kubectl 未安裝，無法連接叢集" "執行 make bootstrap"
    demo::degrade
    return 1
  }
  if ! kubectl cluster-info >/dev/null 2>&1; then
    demo::blocker \
      "連不上 Kubernetes 叢集（KUBECONFIG=${KUBECONFIG:-未設定}）" \
      "執行 make up 建立 ${AEGIS_CLUSTER_NAME} 叢集；或先 make doctor 確認環境"
    demo::degrade
    return 1
  fi
  printf '%s\n' "  ${C_GREEN}OK${C_RESET}    叢集可連線"
  if ! kubectl get ns "$AEGIS_NAMESPACE" >/dev/null 2>&1; then
    demo::blocker "命名空間 ${AEGIS_NAMESPACE} 不存在" "執行 make deploy"
    demo::degrade
    return 1
  fi
  printf '%s\n' "  ${C_GREEN}OK${C_RESET}    命名空間 ${AEGIS_NAMESPACE}"
  return 0
}

# 檢查某個 Deployment 是否有可用副本。
demo::require_deploy() {
  local deploy="$1" ns="${2:-$AEGIS_NAMESPACE}"
  if [ "$DEMO_MODE" != 'live' ]; then
    return 0
  fi
  local ready
  ready="$(kubectl -n "$ns" get "deploy/${deploy}" \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [ -n "$ready" ] && [ "$ready" -gt 0 ] 2>/dev/null; then
    printf '%s\n' "  ${C_GREEN}OK${C_RESET}    ${ns}/${deploy} 有 ${ready} 個可用副本"
    return 0
  fi
  demo::blocker "${ns}/${deploy} 尚未就緒" \
    "執行 make deploy，或 kubectl -n ${ns} describe deploy/${deploy} 看事件"
  demo::degrade
  return 1
}

demo::preflight_header() {
  printf '\n%s\n' "${C_BOLD}前置條件檢查${C_RESET}"
}

# ---------------------------------------------------------------------------
# 分幕
# ---------------------------------------------------------------------------
# demo::scene "幕名" "這一幕要證明什麼" ["補充旁白" ...]
demo::scene() {
  local title="$1"; shift
  DEMO_SCENE_NO=$((DEMO_SCENE_NO + 1))
  printf '\n%s\n' "${C_BLUE}${DEMO_RULE}${C_RESET}"
  printf '%s\n' "${C_BOLD}${C_BLUE}第 ${DEMO_SCENE_NO} 幕${C_RESET}${C_BOLD}　${title}${C_RESET}"
  printf '%s\n' "${C_BLUE}${DEMO_RULE}${C_RESET}"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "  ${C_MAGENTA}要證明的事${C_RESET}"
    demo::narrate "$@"
  fi
  printf '\n'
}

# 每一幕之間的暫停點。只有 --interactive 且 stdin 是終端機時才真的停。
demo::pause() {
  if [ "$DEMO_INTERACTIVE" != 'true' ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 0
  fi
  printf '\n'
  read -r -p "  ${C_DIM}[Enter] 進入下一幕，Ctrl-C 中止…${C_RESET}" _ || true
  printf '\n'
}

# ---------------------------------------------------------------------------
# 指令執行
# ---------------------------------------------------------------------------
# demo::run "<shell 指令字串>"
#
# 一律 return 0，把結束碼放進 DEMO_STATUS、輸出放進 DEMO_OUTPUT，
# 由後續的 demo::assert_* 判定。這樣 set -e 不會在預期失敗的那幾幕把腳本殺掉。
demo::run() {
  local cmd="$1"
  printf '%s\n' "  ${C_DIM}\$${C_RESET} ${C_BOLD}${cmd}${C_RESET}"
  if ! demo::is_executing; then
    printf '%s\n' "  ${C_DIM}│ （未執行：$(demo::mode_label)）${C_RESET}"
    DEMO_STATUS=0
    DEMO_OUTPUT=''
    return 0
  fi
  local tmp
  tmp="$(mktemp -t aegis-demo)"
  set +e
  eval "$cmd" >"$tmp" 2>&1
  DEMO_STATUS=$?
  set -e
  DEMO_OUTPUT="$(cat "$tmp")"
  rm -f "$tmp"
  if [ -n "$DEMO_OUTPUT" ]; then
    printf '%s\n' "$DEMO_OUTPUT" \
      | head -n "$DEMO_MAX_LINES" \
      | sed -e "s/^/  ${C_DIM}│${C_RESET} /"
    local total
    total="$(printf '%s\n' "$DEMO_OUTPUT" | wc -l | tr -d ' ')"
    if [ "$total" -gt "$DEMO_MAX_LINES" ]; then
      printf '%s\n' "  ${C_DIM}│ …（其餘 $((total - DEMO_MAX_LINES)) 行省略，--max-lines 可調整）${C_RESET}"
    fi
  fi
  return 0
}

# 只印指令不執行，並附上為什麼不在這裡真的跑的說明。
# 用在會改變叢集狀態或需要人工在旁觀察的指令（例如 hubble observe --follow）。
demo::show() {
  local cmd="$1" why="${2:-}"
  printf '%s\n' "  ${C_DIM}\$${C_RESET} ${C_BOLD}${cmd}${C_RESET}"
  if [ -n "$why" ]; then
    printf '%s\n' "  ${C_DIM}│ （這裡只展示指令：${why}）${C_RESET}"
  fi
}

# ---------------------------------------------------------------------------
# 判定
# ---------------------------------------------------------------------------
demo::verdict() {
  local kind="$1" desc="$2"
  case "$kind" in
    pass)
      DEMO_PASS=$((DEMO_PASS + 1))
      DEMO_VERDICTS+=("pass|${DEMO_SCENE_NO}|${desc}")
      printf '%s\n' "  ${C_GREEN}✓ 通過${C_RESET}  ${desc}"
      ;;
    fail)
      DEMO_FAIL=$((DEMO_FAIL + 1))
      DEMO_VERDICTS+=("fail|${DEMO_SCENE_NO}|${desc}")
      printf '%s\n' "  ${C_RED}✗ 失敗${C_RESET}  ${desc}"
      ;;
    *)
      DEMO_SKIP=$((DEMO_SKIP + 1))
      DEMO_VERDICTS+=("skip|${DEMO_SCENE_NO}|${desc}")
      printf '%s\n' "  ${C_YELLOW}– 略過${C_RESET}  ${desc}"
      ;;
  esac
}

# 預期成功
demo::assert_ok() {
  local desc="$1"
  if ! demo::is_executing; then demo::verdict skip "$desc"; return 0; fi
  if [ "$DEMO_STATUS" -eq 0 ]; then
    demo::verdict pass "$desc"
  else
    demo::verdict fail "${desc}（結束碼 ${DEMO_STATUS}）"
  fi
}

# 預期失敗。攻擊被擋下來的那幾幕全部用這個 —— 「指令失敗」才是正確結果。
demo::assert_fail() {
  local desc="$1"
  if ! demo::is_executing; then demo::verdict skip "$desc"; return 0; fi
  if [ "$DEMO_STATUS" -ne 0 ]; then
    demo::verdict pass "$desc"
  else
    demo::verdict fail "${desc}（指令竟然成功了，這代表防禦沒生效）"
  fi
}

# 預期輸出包含某個字串
demo::assert_contains() {
  local needle="$1" desc="$2"
  if ! demo::is_executing; then demo::verdict skip "$desc"; return 0; fi
  case "$DEMO_OUTPUT" in
    *"$needle"*) demo::verdict pass "$desc" ;;
    *)           demo::verdict fail "${desc}（輸出中找不到「${needle}」）" ;;
  esac
}

# 預期輸出不包含某個字串。用來證明「日誌裡沒有原始 PII」這類負向命題。
demo::assert_absent() {
  local needle="$1" desc="$2"
  if ! demo::is_executing; then demo::verdict skip "$desc"; return 0; fi
  case "$DEMO_OUTPUT" in
    *"$needle"*) demo::verdict fail "${desc}（輸出中竟然出現「${needle}」）" ;;
    *)           demo::verdict pass "$desc" ;;
  esac
}

# 預期 HTTP 狀態碼。搭配 curl -o /dev/null -w '%{http_code}' 使用。
demo::assert_http() {
  local expected="$1" desc="$2"
  if ! demo::is_executing; then demo::verdict skip "${desc}（預期 HTTP ${expected}）"; return 0; fi
  local got
  got="$(printf '%s' "$DEMO_OUTPUT" | tr -d '[:space:]')"
  if [ "$got" = "$expected" ]; then
    demo::verdict pass "${desc} → HTTP ${got}"
  else
    demo::verdict fail "${desc} → 預期 HTTP ${expected}，實際得到「${got:-無回應}」"
  fi
}

# ---------------------------------------------------------------------------
# 連接埠轉發（用完自動收）
# ---------------------------------------------------------------------------
demo::_cleanup() {
  local pid
  if [ "${#DEMO_PF_PIDS[@]}" -gt 0 ]; then
    for pid in "${DEMO_PF_PIDS[@]}"; do
      kill "$pid" >/dev/null 2>&1 || true
    done
  fi
}

demo::port_forward() {
  local ns="$1" target="$2" mapping="$3"
  printf '%s\n' "  ${C_DIM}\$${C_RESET} ${C_BOLD}kubectl -n ${ns} port-forward ${target} ${mapping} &${C_RESET}"
  if ! demo::is_executing; then
    printf '%s\n' "  ${C_DIM}│ （未執行：$(demo::mode_label)）${C_RESET}"
    return 0
  fi
  kubectl -n "$ns" port-forward "$target" "$mapping" >/dev/null 2>&1 &
  DEMO_PF_PIDS+=("$!")
  # 給 port-forward 一點時間建立通道，否則第一發 curl 會拿到 connection refused。
  sleep 3
  demo::info "已在背景建立 ${ns}/${target} 的 ${mapping} 通道（腳本結束時自動關閉）"
}

# ---------------------------------------------------------------------------
# 開場與收場
# ---------------------------------------------------------------------------
demo::header() {
  DEMO_NAME="$1"; DEMO_DATE="$2"; DEMO_TAGLINE="$3"
  trap demo::_cleanup EXIT
  printf '\n%s\n' "${C_CYAN}${DEMO_RULE}${C_RESET}"
  printf '%s\n' "${C_BOLD}  Aegis-Enclave 展示　—　${DEMO_NAME}${C_RESET}"
  printf '%s\n' "  ${C_DIM}${DEMO_DATE}${C_RESET}"
  printf '%s\n' "  ${DEMO_TAGLINE}"
  printf '%s\n' "  執行模式：$(demo::mode_label)"
  printf '%s\n\n' "${C_CYAN}${DEMO_RULE}${C_RESET}"
}

# demo::rubric "評分項目|本次 demo 如何對應"
demo::rubric() {
  DEMO_RUBRIC+=("$1")
}

demo::summary() {
  local entry kind scene desc item

  printf '\n%s\n' "${C_CYAN}${DEMO_RULE}${C_RESET}"
  printf '%s\n' "${C_BOLD}  收場　—　${DEMO_NAME}${C_RESET}"
  printf '%s\n\n' "${C_CYAN}${DEMO_RULE}${C_RESET}"

  printf '%s\n' "${C_BOLD}逐幕判定${C_RESET}"
  if [ "${#DEMO_VERDICTS[@]}" -gt 0 ]; then
    for entry in "${DEMO_VERDICTS[@]}"; do
      kind="${entry%%|*}"
      scene="${entry#*|}"; scene="${scene%%|*}"
      desc="${entry##*|}"
      case "$kind" in
        pass) printf '%s\n' "  ${C_GREEN}✓${C_RESET} 第 ${scene} 幕　${desc}" ;;
        fail) printf '%s\n' "  ${C_RED}✗${C_RESET} 第 ${scene} 幕　${desc}" ;;
        *)    printf '%s\n' "  ${C_YELLOW}–${C_RESET} 第 ${scene} 幕　${desc}" ;;
      esac
    done
  else
    printf '%s\n' "  ${C_DIM}（無）${C_RESET}"
  fi
  printf '\n%s\n' "  合計：${C_GREEN}${DEMO_PASS} 通過${C_RESET} / ${C_RED}${DEMO_FAIL} 失敗${C_RESET} / ${C_YELLOW}${DEMO_SKIP} 略過${C_RESET}"

  if [ "${#DEMO_RUBRIC[@]}" -gt 0 ]; then
    printf '\n%s\n' "${C_BOLD}評分對應${C_RESET}"
    for item in "${DEMO_RUBRIC[@]}"; do
      printf '%s\n' "  ${C_CYAN}▸${C_RESET} ${C_BOLD}${item%%|*}${C_RESET}"
      printf '%s\n' "      ${item#*|}"
    done
  fi

  if [ "${#DEMO_BLOCKERS[@]}" -gt 0 ]; then
    printf '\n%s\n' "${C_BOLD}${C_YELLOW}未滿足的前置條件${C_RESET}"
    for entry in "${DEMO_BLOCKERS[@]}"; do
      printf '%s\n' "  ${C_YELLOW}!${C_RESET} ${entry%%|*}"
      printf '%s\n' "      ${C_DIM}修復：${entry#*|}${C_RESET}"
    done
  fi

  printf '\n'
  case "$DEMO_MODE" in
    dry)
      printf '%s\n' "  ${C_YELLOW}這是 --dry-run 預演${C_RESET}：上面每一幕都只印出指令。"
      printf '%s\n' "  正式展示前請先 ${C_BOLD}make up${C_RESET} 拉起叢集，再拿掉 --dry-run。"
      ;;
    degraded)
      printf '%s\n' "  ${C_YELLOW}降級模式${C_RESET}：前置條件不足，指令未實際執行（見上方清單）。"
      printf '%s\n' "  腳本刻意不在此中止，讓你仍能完整看過分幕結構與每一幕的意圖。"
      ;;
    *)
      if [ "$DEMO_FAIL" -gt 0 ]; then
        printf '%s\n' "  ${C_RED}有 ${DEMO_FAIL} 項判定失敗${C_RESET}，請照上面的訊息逐項排查。"
      else
        printf '%s\n' "  ${C_GREEN}全部判定通過。${C_RESET}"
      fi
      ;;
  esac
  printf '%s\n' "  主持稿與評審提問準備：${C_BOLD}docs/demo/${C_RESET}"
  printf '%s\n\n' "${C_CYAN}${DEMO_RULE}${C_RESET}"

  # 刻意不因為判定失敗就回傳非零 —— 現場展示時 exit code 沒人看，
  # 但 CI 需要知道 --dry-run 有沒有跑完，所以只要走到這裡就算成功。
  return 0
}

# ---------------------------------------------------------------------------
# 直接執行時的守門：這是函式庫，不是 demo。
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  printf '%s\n' "scripts/demo-lib.sh 是五支 demo 腳本共用的函式庫，不是可獨立執行的展示。"
  printf '%s\n' "請執行下列其中一支（都支援 --dry-run）："
  printf '%s\n' "  ./scripts/demo-tln.sh           零信任閘道與 SIEM 稽核"
  printf '%s\n' "  ./scripts/demo-fincyber.sh      PII 遮罩與 KMS 金鑰生命週期"
  printf '%s\n' "  ./scripts/demo-forgehacks.sh    容器邊界防禦與映像掃描"
  printf '%s\n' "  ./scripts/demo-climatechain.sh  碳權合約測試與靜態分析"
  printf '%s\n' "  ./scripts/demo-hacktitan.sh     IaC、微分段與可觀測性"
  exit 0
fi
