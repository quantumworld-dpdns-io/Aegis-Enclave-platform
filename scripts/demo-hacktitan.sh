#!/usr/bin/env bash
#
# HackTitan 展示腳本
#
# 主題：基礎設施即程式碼 + 預設拒絕微分段 + 可觀測性。
# 從 Terraform 一鍵拉起 Kind，到 attacker Pod 被 eBPF 丟掉、Hubble 現形、
# Grafana 亮起 AegisCiliumPolicyDropSpike。macOS 上 KPR 預設關閉（ADR 0002）。
#
# 對應 CCSP Domain 3 / 5。主持稿見 docs/demo/hacktitan.md。
set -euo pipefail

# shellcheck source=scripts/demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/demo-lib.sh"

demo::parse_args "$@"

demo::header \
  "HackTitan —— IaC、微分段與可觀測性" \
  "2027-02　｜　CCSP Domain 3 / 5" \
  "叢集不是手點出來的：Terraform 描述、Cilium 預設拒絕、攻擊被丟掉而且會叫。"

demo::preflight_header
demo::require_cmd kubectl    "執行 make bootstrap"
demo::optional_cmd terraform "沒有仍可看已套用的資源；重建叢集才需要"
demo::optional_cmd helm      "Cilium 與 kube-prometheus-stack 由 Terraform helm provider 安裝"
demo::optional_cmd hubble    "缺少時改用 Hubble 指標與 kubectl 日誌"
demo::optional_cmd cilium    "缺少時仍可由 Helm 裝好的 Cilium 運作"
demo::require_cluster
demo::require_deploy gateway
demo::require_deploy dataplane

demo::pause

# ---------------------------------------------------------------------------
demo::scene "IaC：叢集參數全部可審查" \
  "tehcyx/kind provider pin kindest/node:v1.31.0，不吃 provider 過期預設值。" \
  "Cilium 1.20.1、kube-prometheus-stack、host 綁 127.0.0.1，都寫在 variables.tf。" \
  "評審要看的是『改一個變數就能重現』，不是截圖裡剛好有一座叢集。"

demo::run "grep -E 'default\\s*=\\s*\"(aegis-enclave|kindest/node|1\\.20\\.1)' infra/terraform/variables.tf"
demo::assert_contains "kindest/node:v1.31.0" "node_image 明確 pin 在契約版本"

demo::run "ls infra/terraform/versions.tf infra/terraform/variables.tf"
demo::assert_ok "根模組的版本鎖定與輸入變數都在版控裡"

demo::narrate "" \
  "Grafana 預設密碼只適用本機 demo，且 validation 拒絕 admin/password 這類弱密碼。" \
  "正式環境改走 existingSecret，不要把密碼放進 tfvars。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "ADR 0002：macOS 上 kube-proxy replacement 預設關閉" \
  "這是本專案最大的環境風險，也是評審最容易問倒的一題。" \
  "KPR 與 Socket LB 需要 cgroup v2 與獨立 cgroup namespace；" \
  "Docker Desktop 的 LinuxKit VM 通常不滿足，開啟後 cilium-agent 會 CrashLoop。" \
  "關閉 KPR 時 NetworkPolicy 與 Hubble 仍完整可用 —— demo 需要的都在。"

demo::run "grep -A 8 'variable \"enable_kube_proxy_replacement\"' infra/terraform/variables.tf | head -20"
demo::assert_contains "false" "enable_kube_proxy_replacement 預設為 false"

demo::show "terraform apply -var enable_kube_proxy_replacement=true" \
  "只在 Linux + cgroup v2 宿主機開啟；開啟後必須 destroy 才能關回去"
demo::narrate "" \
  "完整決策：docs/adr/0002-ebpf-on-macos.md" \
  "make doctor 在 Darwin 上會主動印出同一段警告。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "預設拒絕：沒寫進策略的路徑就不存在" \
  "Cilium 以 default-deny 起步，再逐條開放 gateway ↔ dataplane、探針、KMS、鏈。" \
  "策略檔在 infra/k8s/policies/；沒套用就不該看得到跨命名空間的 FORWARDED。"

demo::run "kubectl get ciliumnetworkpolicy -A -o wide 2>/dev/null || kubectl get cnp -A -o wide 2>/dev/null || echo '尚無 CiliumNetworkPolicy（模組 E 部署後才會有）'"
if [ "$DEMO_MODE" = 'live' ]; then
  case "$DEMO_OUTPUT" in
    *CiliumNetworkPolicy*|*NAME*|*尚無*) demo::verdict pass "已查詢叢集內的 Cilium 網路策略" ;;
    *) demo::verdict skip "目前查不到 CNP 資源，後續攻擊幕會略過或降級" ;;
  esac
else
  demo::verdict skip "預演模式：只印出查詢指令"
fi
demo::pause

# ---------------------------------------------------------------------------
demo::scene "攻擊模擬：attacker 直連 dataplane" \
  "CONTRACT.md 第 1 節規定 attacker 命名空間專供紅隊驗證。" \
  "從那裡打 dataplane:8000 必須被 L3/L4 丟掉，不是應用層 401。" \
  "Kind 展示關閉閘道 mTLS（ADR 0003），所以這一層證明的是網路身分，不是 TLS。"

demo::run "kubectl -n ${AEGIS_ATTACKER_NAMESPACE} get pod -o wide 2>/dev/null || echo 'attacker 命名空間尚無探針 Pod'"

demo::show "kubectl -n attacker run attack-sim --rm -it --image=curlimages/curl:8.11.1 -- \\
  curl -sS -m 5 http://dataplane.aegis.svc.cluster.local:8000/internal/v1/records" \
  "真實攻擊模擬由 scripts/attack-sim/ 啟動；現場若已有探針就改用下面這發"

demo::run "kubectl -n ${AEGIS_ATTACKER_NAMESPACE} run aegis-ht-probe --restart=Never --image=curlimages/curl:8.11.1 -- \\
  curl -sS -m 5 -o /dev/null -w '%{http_code}' \\
  http://dataplane.${AEGIS_NAMESPACE}.svc.cluster.local:8000/internal/healthz \\
  && kubectl -n ${AEGIS_ATTACKER_NAMESPACE} wait --for=jsonpath='{.status.phase}'=Succeeded pod/aegis-ht-probe --timeout=20s; \\
  kubectl -n ${AEGIS_ATTACKER_NAMESPACE} logs pod/aegis-ht-probe; \\
  kubectl -n ${AEGIS_ATTACKER_NAMESPACE} delete pod/aegis-ht-probe --wait=false"
# 成功連上（拿到 HTTP 碼）才是失敗；逾時 / 連線被拒才是通過。
# dry-run 會 skip；live 時結束碼非零代表被擋。
demo::assert_fail "attacker 直連 dataplane 失敗（微分段生效）"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "Hubble：丟掉的封包要看得見" \
  "偵測不到的策略等於沒寫。Hubble 的 verdict=DROPPED 是給評審看的證物。" \
  "macOS 關 KPR 不影響 drop / flow / http 指標（ADR 0002）。"

if demo::have hubble; then
  demo::run "hubble observe --verdict DROPPED --last 20"
  demo::assert_ok "Hubble 回得了 DROPPED 觀測"
else
  demo::show "hubble observe --follow --verdict DROPPED" \
    "本機沒有 hubble CLI；改拉 Prometheus 的 hubble_drop_total"
  demo::run "kubectl -n ${AEGIS_OBS_NAMESPACE} get svc -o name 2>/dev/null | grep -i prometheus | head -5"
  demo::verdict skip "缺少 hubble CLI，改以指標與服務清單代替即時 observe"
fi
demo::pause

# ---------------------------------------------------------------------------
demo::scene "告警：策略拒絕會叫，attacker 流量零容忍" \
  "AegisCiliumPolicyDropSpike：來源→目的的 policy denied 速率超標。" \
  "AegisAttackerNamespaceTrafficDetected：attacker 一出流量就 critical（for: 0m）。" \
  "兩條一起亮，才是『偵測 + 攔截』都有效。"

demo::run "grep -E 'alert: Aegis(CiliumPolicyDropSpike|AttackerNamespaceTrafficDetected)' \\
  infra/observability/prometheus/rules/microsegmentation.yaml"
demo::assert_contains "AegisCiliumPolicyDropSpike" "微分段規則檔含策略拒絕告警"
demo::assert_contains "AegisAttackerNamespaceTrafficDetected" "微分段規則檔含 attacker 零容忍告警"

demo::show "kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80" \
  "另開終端機；帳密見 docs/demo/README.md"
demo::narrate "" \
  "儀表板「Aegis / 微分段」：策略拒絕熱點、attacker 流量、Hubble drop reason。" \
  "規則標籤 competition=hacktitan、ccsp_domain=5，方便評審對回評分表。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "L7 與 L3 的差別：同一套策略兩種證物" \
  "閘道 Pod 打 /internal/v1/keys → HTTP 403（L7 感知，看得到路徑）。" \
  "attacker 直連 → DROPPED（L3/L4，連 HTTP 都走不成）。" \
  "評審若問『為什麼一個 403、一個超時』，答案就在這一幕。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} debug \\
  \"\$(kubectl -n ${AEGIS_NAMESPACE} get pod -l app.kubernetes.io/name=gateway -o jsonpath='{.items[0].metadata.name}')\" \\
  -q --image=curlimages/curl:8.11.1 -- \\
  curl -sS -m 8 -o /dev/null -w '%{http_code}' \\
  http://dataplane.${AEGIS_NAMESPACE}.svc.cluster.local:8000/internal/v1/keys"
demo::assert_http 403 "閘道身分打非白名單路徑得到 L7 403"
demo::pause

# ---------------------------------------------------------------------------
demo::rubric "基礎設施即程式碼|Kind 節點映像、Cilium 版本、KPR 開關、Grafana 密碼政策全部在 Terraform 變數裡，可審查、可重現。"
demo::rubric "macOS eBPF 誠實揭露|KPR 預設關，NetworkPolicy 與 Hubble 仍可用。ADR 0002 與 make doctor 講同一句話，不讓評審以為我們藏了 CrashLoop。"
demo::rubric "預設拒絕微分段|attacker 直連被丟、閘道越權路徑 403。第 4、5、7 幕是同一條策略的兩種證物。"
demo::rubric "可觀測性閉環|hubble_drop_total → PromQL → Grafana。攻擊模擬本身會觸發 AegisAttackerNamespaceTrafficDetected。"
demo::rubric "CCSP Domain 3 / 5 對照|平台組態、網路隔離、事件偵測。逐項見 docs/ccsp-mapping.md。"

demo::summary
