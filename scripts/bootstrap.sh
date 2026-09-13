#!/usr/bin/env bash
#
# 安裝 Aegis-Enclave 所需但本機尚未具備的工具鏈。
# 已存在的工具會被跳過，重複執行是安全的（idempotent）。
set -euo pipefail

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

info()  { echo -e "${GREEN}[安裝]${NC} $*"; }
skip()  { echo -e "${YELLOW}[略過]${NC} $*"; }
fail()  { echo -e "${RED}[失敗]${NC} $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# brew 是 macOS 上大部分工具的安裝來源，沒有它就無法繼續。
if ! have brew; then
  fail "找不到 Homebrew。請先安裝：https://brew.sh"
fi

# --- Kubernetes 工具鏈 ---
install_brew_pkg() {
  local cmd="$1" pkg="$2"
  if have "$cmd"; then
    skip "$cmd 已安裝 ($(command -v "$cmd"))"
  else
    info "以 brew 安裝 $pkg"
    brew install "$pkg"
  fi
}

install_brew_pkg kind   kind
install_brew_pkg helm   helm
install_brew_pkg cilium cilium-cli
install_brew_pkg hubble hubble
install_brew_pkg kubectl kubernetes-cli
install_brew_pkg terraform hashicorp/tap/terraform
install_brew_pkg jq     jq

# --- Foundry（Solidity 工具鏈）---
# Foundry 不走 brew，官方安裝器會把 forge/cast/anvil/chisel 放到 ~/.foundry/bin。
if have forge; then
  skip "Foundry 已安裝 ($(forge --version 2>/dev/null | head -1))"
else
  info "安裝 Foundry (forge / cast / anvil / chisel)"
  curl -fsSL https://getfoundry.sh/install | bash
  # 安裝器只改寫 shell profile，當前 session 需自行加入 PATH。
  export PATH="$HOME/.foundry/bin:$PATH"
  foundryup
  echo -e "${YELLOW}提醒${NC}：請重新開啟終端機，或執行 export PATH=\"\$HOME/.foundry/bin:\$PATH\""
fi

# --- uv（Python 套件與虛擬環境管理）---
if have uv; then
  skip "uv 已安裝 ($(uv --version))"
else
  info "以 brew 安裝 uv"
  brew install uv
fi

# --- Trivy 與 Slither 刻意不安裝在本機 ---
# 兩者都透過官方 Docker 映像執行（見 Makefile 的 TRIVY / SLITHER 變數），
# 好處是掃描器版本與 CI 完全一致，且不會在開發機累積 Python 相依衝突。
if have docker; then
  info "預先拉取掃描器映像（可離線 demo）"
  docker pull aquasec/trivy:latest &
  docker pull trailofbits/eth-security-toolbox:latest &
  wait
else
  fail "找不到 docker。Kind 叢集與安全掃描都依賴它。"
fi

echo ""
info "工具鏈準備完成。接著執行： make doctor"
