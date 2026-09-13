#!/usr/bin/env bash
#
# 檢查本機是否具備跑完整 Aegis-Enclave demo 的條件。
# 不做任何修改，純檢測；有問題時給出可執行的修正建議。
set -uo pipefail

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

failures=0
warnings=0

ok()   { echo -e "  ${GREEN}OK${NC}    $*"; }
warn() { echo -e "  ${YELLOW}注意${NC}  $*"; warnings=$((warnings + 1)); }
bad()  { echo -e "  ${RED}缺少${NC}  $*"; failures=$((failures + 1)); }

check_cmd() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd"
  else
    bad "$cmd —— $hint"
  fi
}

# 比較 major.minor，have >= need 則回傳 0。不依賴 GNU sort -V。
version_ge() {
  local have="$1" need="$2"
  local have_major have_minor need_major need_minor
  have_major="${have%%.*}"
  have_minor="${have#*.}"
  have_minor="${have_minor%%.*}"
  need_major="${need%%.*}"
  need_minor="${need#*.}"
  need_minor="${need_minor%%.*}"
  have_major="${have_major:-0}"
  have_minor="${have_minor:-0}"
  need_major="${need_major:-0}"
  need_minor="${need_minor:-0}"
  if [ "$have_major" -gt "$need_major" ]; then
    return 0
  fi
  if [ "$have_major" -eq "$need_major" ] && [ "$have_minor" -ge "$need_minor" ]; then
    return 0
  fi
  return 1
}

check_go() {
  if ! command -v go >/dev/null 2>&1; then
    bad "go —— 請安裝 Go 1.23 以上"
    return
  fi
  local raw ver
  raw="$(go version 2>/dev/null || true)"
  ver="$(printf '%s' "$raw" | sed -n 's/.*go\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  if [ -z "$ver" ]; then
    bad "go —— 無法解析版本（${raw}），請安裝 Go 1.23 以上"
    return
  fi
  if version_ge "$ver" "1.23"; then
    ok "go ${ver}（1.23 以上）"
  else
    bad "go ${ver} —— 需要 Go 1.23 以上"
  fi
}

check_python() {
  local cmd="" raw ver
  if command -v python3 >/dev/null 2>&1; then
    cmd="python3"
  elif command -v python >/dev/null 2>&1; then
    cmd="python"
  else
    bad "python —— 請安裝 Python 3.12 以上"
    return
  fi
  raw="$("$cmd" --version 2>&1 || true)"
  ver="$(printf '%s' "$raw" | sed -n 's/.*[Pp]ython \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  if [ -z "$ver" ]; then
    bad "python —— 無法解析版本（${raw}），請安裝 Python 3.12 以上"
    return
  fi
  if version_ge "$ver" "3.12"; then
    ok "python ${ver}（3.12 以上）"
  else
    bad "python ${ver} —— 需要 Python 3.12 以上"
  fi
}

echo ""
echo "Aegis-Enclave 環境檢查"
echo "======================"
echo ""
echo "必要工具："
check_cmd docker    "請安裝 Docker Desktop 或 Colima"
check_cmd kind      "執行 make bootstrap"
check_cmd kubectl   "執行 make bootstrap"
check_cmd helm      "執行 make bootstrap"
check_cmd terraform "執行 make bootstrap"
check_go
check_python
check_cmd uv        "執行 make bootstrap"
check_cmd forge     "執行 make bootstrap，並確認 ~/.foundry/bin 在 PATH 中"

echo ""
echo "選用工具（缺少時會退化為較陽春的展示）："
command -v cilium >/dev/null 2>&1 && ok "cilium CLI" || warn "cilium CLI 缺少，Cilium 仍可由 Terraform 的 helm provider 安裝"
command -v hubble >/dev/null 2>&1 && ok "hubble CLI" || warn "hubble CLI 缺少，將無法在終端機觀察即時攔截事件"
command -v jq     >/dev/null 2>&1 && ok "jq"         || warn "jq 缺少，demo 腳本的輸出會較難閱讀"

echo ""
echo "Docker 執行環境："
if docker info >/dev/null 2>&1; then
  cpus=$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)
  mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  mem_gb=$((mem_bytes / 1024 / 1024 / 1024))
  ok "Docker daemon 運作中（CPU ${cpus} 核 / 記憶體 ${mem_gb} GB）"

  # Kind 控制平面 + Cilium + Prometheus + Grafana 的實測底線約為 6 GB。
  if [ "$mem_gb" -lt 6 ]; then
    warn "配置給 Docker 的記憶體僅 ${mem_gb} GB，建議調高到 8 GB 以上，否則 Prometheus 可能被 OOMKilled"
  fi
  if [ "$cpus" -lt 4 ]; then
    warn "配置給 Docker 的 CPU 僅 ${cpus} 核，建議調高到 4 核以上"
  fi
else
  bad "Docker daemon 未啟動"
fi

echo ""
echo "eBPF 能力（影響 Cilium 可展示的深度）："
case "$(uname -s)" in
  Darwin)
    warn "macOS 上 Docker 跑在 Linux VM 中，Cilium 的 kubeProxyReplacement 與 Socket LB 通常無法啟用"
    echo "        預設組態已關閉 KPR，NetworkPolicy 與 Hubble 仍完整可用（demo 所需功能都在）"
    echo "        細節與替代方案見 docs/adr/0002-ebpf-on-macos.md"
    ;;
  Linux)
    if [ -d /sys/fs/bpf ]; then
      ok "偵測到 bpffs，可啟用完整 eBPF 資料面（terraform apply -var enable_kube_proxy_replacement=true）"
    else
      warn "找不到 /sys/fs/bpf，kubeProxyReplacement 可能無法啟用"
    fi
    ;;
esac

echo ""
echo "----------------------------------------"
if [ "$failures" -gt 0 ]; then
  echo -e "${RED}${failures} 項必要工具缺少${NC}，${warnings} 項提醒。請先執行 make bootstrap。"
  exit 1
fi
echo -e "${GREEN}環境檢查通過${NC}（${warnings} 項提醒）。接著執行： make up"
exit 0
