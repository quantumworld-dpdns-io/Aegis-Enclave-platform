#!/usr/bin/env bash
#
# 微分段攻防對照。同時是 HackTitan / ForgeHacks 的現場 demo，
# 也是 CI e2e-kind 的驗收：任一情境 FAIL 就以非零結束碼退出。
#
# 五個情境：
#   1. attacker 直連 dataplane          → L3/L4 丟棄（逾時 / 連不上）
#   2. 以 gateway 身分打未授權路徑     → L7 回 403
#   3. 以 gateway 身分打 /internal/healthz → 200（對照組）
#   4. 以 dataplane 身分外連 example.com → egress 擋
#   5. Hubble 看得到 DROPPED
#
# 相容 macOS bash 3.2：不用 associative array、mapfile、${var,,}。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

AEGIS_NS="${AEGIS_NAMESPACE:-aegis}"
ATTACKER_NS="${AEGIS_ATTACKER_NAMESPACE:-attacker}"
DATAPLANE_URL="${AEGIS_DATAPLANE_URL:-http://dataplane.${AEGIS_NS}.svc.cluster.local:8000}"
CURL_TIMEOUT="${AEGIS_ATTACK_CURL_TIMEOUT:-8}"

ATTACKER_POD="attack-sim-attacker"
GATEWAY_PROBE="attack-sim-gateway-probe"
DATAPLANE_PROBE="attack-sim-dataplane-probe"

PASS=0
FAIL=0
CLEANED=0

# ---------------------------------------------------------------------------
# 輸出
# ---------------------------------------------------------------------------
say() { printf '%s\n' "$*"; }
hr() { say "------------------------------------------------------------------------"; }

# judge <名稱> <預期> <實際> <0=FAIL 1=PASS>
judge() {
  local name="$1" expected="$2" actual="$3" ok="$4"
  say ""
  say "情境：${name}"
  say "  預期：${expected}"
  say "  實際：${actual}"
  if [ "$ok" = "1" ]; then
    say "  判定：PASS"
    PASS=$((PASS + 1))
  else
    say "  判定：FAIL"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# 清理：刪探針，避免下次跑到殘留 Pod。
# ---------------------------------------------------------------------------
cleanup() {
  if [ "$CLEANED" = "1" ]; then
    return 0
  fi
  CLEANED=1
  kubectl -n "$ATTACKER_NS" delete pod "$ATTACKER_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$AEGIS_NS" delete pod "$GATEWAY_PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$AEGIS_NS" delete pod "$DATAPLANE_PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 前置
# ---------------------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  say "缺少 kubectl，無法執行攻擊模擬。"
  exit 2
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  say "連不上 Kubernetes 叢集（KUBECONFIG=${KUBECONFIG:-未設定}）。"
  say "請先 make up，再跑本腳本。"
  exit 2
fi

say "Aegis-Enclave 攻擊模擬"
hr
say "dataplane = ${DATAPLANE_URL}"
say "套用探針 Pod（gateway/dataplane 標籤不含 component=server，避免污染 Service）"

kubectl apply -f "${MANIFEST_DIR}/attacker-pod.yaml"
kubectl apply -f "${MANIFEST_DIR}/gateway-probe.yaml"
kubectl apply -f "${MANIFEST_DIR}/dataplane-probe.yaml"

kubectl -n "$ATTACKER_NS" wait --for=condition=Ready "pod/${ATTACKER_POD}" --timeout=120s
kubectl -n "$AEGIS_NS" wait --for=condition=Ready "pod/${GATEWAY_PROBE}" --timeout=120s
kubectl -n "$AEGIS_NS" wait --for=condition=Ready "pod/${DATAPLANE_PROBE}" --timeout=120s

# 在探針裡跑 curl。結束碼放進第三個 nameref 參數；stdout 是 HTTP 狀態碼或錯誤字串。
# 不用 set -e 包住 curl：逾時與被拒都是「預期失敗」。
probe_curl() {
  local ns="$1" pod="$2"
  shift 2
  local out rc
  set +e
  out="$(kubectl -n "$ns" exec "$pod" -- curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" "$@" 2>&1)"
  rc=$?
  set -e
  PROBE_RC="$rc"
  PROBE_OUT="$out"
}

# ---------------------------------------------------------------------------
# 1. 繞過閘道直連
# ---------------------------------------------------------------------------
probe_curl "$ATTACKER_NS" "$ATTACKER_POD" "${DATAPLANE_URL}/internal/healthz"
# 連線被丟：curl 非零（逾時 28、連不上 7、解析後 RST 等），或 HTTP 碼 000。
case "$PROBE_OUT" in
  000|'') dropped=1 ;;
  *) dropped=0 ;;
esac
if [ "$PROBE_RC" -ne 0 ] || [ "$dropped" = "1" ]; then
  judge \
    "繞過閘道直連資料面" \
    "L3/L4 丟棄（逾時或連不上，沒有 HTTP 2xx）" \
    "curl 結束碼=${PROBE_RC} 輸出=${PROBE_OUT}" \
    1
else
  judge \
    "繞過閘道直連資料面" \
    "L3/L4 丟棄（逾時或連不上，沒有 HTTP 2xx）" \
    "竟然拿到 HTTP ${PROBE_OUT}，微分段被穿透" \
    0
fi

# ---------------------------------------------------------------------------
# 2. 合法來源、未授權路徑
# ---------------------------------------------------------------------------
probe_curl "$AEGIS_NS" "$GATEWAY_PROBE" "${DATAPLANE_URL}/internal/v1/keys"
if [ "$PROBE_OUT" = "403" ]; then
  judge \
    "以閘道身分存取未授權路徑 /internal/v1/keys" \
    "Cilium L7 回 HTTP 403" \
    "HTTP ${PROBE_OUT}" \
    1
else
  judge \
    "以閘道身分存取未授權路徑 /internal/v1/keys" \
    "Cilium L7 回 HTTP 403" \
    "curl 結束碼=${PROBE_RC} 輸出=${PROBE_OUT}" \
    0
fi

# ---------------------------------------------------------------------------
# 3. 合法路徑對照組
# ---------------------------------------------------------------------------
probe_curl "$AEGIS_NS" "$GATEWAY_PROBE" "${DATAPLANE_URL}/internal/healthz"
if [ "$PROBE_OUT" = "200" ]; then
  judge \
    "以閘道身分存取合法路徑 /internal/healthz" \
    "HTTP 200（證明不是整張網路都壞掉）" \
    "HTTP ${PROBE_OUT}" \
    1
else
  judge \
    "以閘道身分存取合法路徑 /internal/healthz" \
    "HTTP 200（證明不是整張網路都壞掉）" \
    "curl 結束碼=${PROBE_RC} 輸出=${PROBE_OUT}" \
    0
fi

# ---------------------------------------------------------------------------
# 4. 資料面出向外流
# ---------------------------------------------------------------------------
probe_curl "$AEGIS_NS" "$DATAPLANE_PROBE" "https://example.com"
egress_blocked=0
case "$PROBE_OUT" in
  2??) egress_blocked=0 ;;
  *)
    if [ "$PROBE_RC" -ne 0 ]; then
      egress_blocked=1
    elif [ "$PROBE_OUT" = "000" ] || [ -z "$PROBE_OUT" ]; then
      egress_blocked=1
    fi
    ;;
esac
if [ "$egress_blocked" = "1" ]; then
  judge \
    "資料面出向外連 https://example.com" \
    "egress / L7 DNS 阻擋（解析失敗、逾時或連不上）" \
    "curl 結束碼=${PROBE_RC} 輸出=${PROBE_OUT}" \
    1
else
  judge \
    "資料面出向外連 https://example.com" \
    "egress / L7 DNS 阻擋（解析失敗、逾時或連不上）" \
    "竟然拿到 HTTP ${PROBE_OUT}，外流防護失效" \
    0
fi

# ---------------------------------------------------------------------------
# 5. Hubble 佐證 DROPPED
# 給 Hubble 一點時間把情境一的 drop 寫進 ring buffer。
# ---------------------------------------------------------------------------
sleep 2
HUBBLE_OUT=""
HUBBLE_SRC="無"

if command -v hubble >/dev/null 2>&1; then
  set +e
  HUBBLE_OUT="$(hubble observe --verdict DROPPED --last 50 --since 10m 2>&1)"
  hubble_rc=$?
  set -e
  if [ "$hubble_rc" -eq 0 ]; then
    HUBBLE_SRC="hubble CLI"
  fi
fi

if [ -z "$HUBBLE_SRC" ] || [ "$HUBBLE_SRC" = "無" ]; then
  cilium_pod="$(kubectl -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$cilium_pod" ]; then
    set +e
    HUBBLE_OUT="$(kubectl -n kube-system exec "$cilium_pod" -- \
      hubble observe --verdict DROPPED --last 50 2>&1)"
    hubble_rc=$?
    set -e
    if [ "$hubble_rc" -eq 0 ]; then
      HUBBLE_SRC="kubectl exec ${cilium_pod} -- hubble"
    else
      set +e
      HUBBLE_OUT="$(kubectl -n kube-system exec "$cilium_pod" -- \
        cilium-dbg monitor --type drop -n 20 2>&1)"
      hubble_rc=$?
      set -e
      if [ "$hubble_rc" -eq 0 ]; then
        HUBBLE_SRC="kubectl exec ${cilium_pod} -- cilium-dbg"
      fi
    fi
  fi
fi

# 印前 20 行給評審看，完整內容仍用來判定。
if [ -n "$HUBBLE_OUT" ]; then
  say ""
  say "Hubble / cilium 輸出（來源：${HUBBLE_SRC}，前 20 行）："
  # pipefail + head 提前關管線會讓前端吃到 SIGPIPE，這裡允許非零。
  printf '%s\n' "$HUBBLE_OUT" | head -n 20 | sed 's/^/  | /' || true
fi

case "$HUBBLE_OUT" in
  *DROPPED*|*dropped*|*Policy\ denied*|*POLICY_DENIED*|*drop*)
    judge \
      "Hubble 佐證攔截事件" \
      "觀察到 DROPPED / Policy denied" \
      "來源=${HUBBLE_SRC}，輸出含丟棄判定" \
      1
    ;;
  *)
    judge \
      "Hubble 佐證攔截事件" \
      "觀察到 DROPPED / Policy denied" \
      "來源=${HUBBLE_SRC:-無}，輸出中找不到 DROPPED。可改跑：hubble observe --verdict DROPPED --last 50" \
      0
    ;;
esac

# ---------------------------------------------------------------------------
# 總結
# ---------------------------------------------------------------------------
say ""
hr
say "總結：PASS=${PASS}  FAIL=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  say "有情境失敗，微分段未完全生效。"
  exit 1
fi
say "五個情境全部通過。"
exit 0
