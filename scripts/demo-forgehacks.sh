#!/usr/bin/env bash
#
# ForgeHacks 展示腳本
#
# 主題：容器邊界防禦 —— 在網路策略生效之前，先讓惡意 workload 根本排不進去。
# 這一場從 Pod Security Admission、securityContext、映像掃描一路走到
# 「就算 RCE 了也只拿到 uid 10001、不能寫根檔、沒有 SA token」。
#
# 對應 CCSP Domain 3 / 5。主持稿見 docs/demo/forgehacks.md。
set -euo pipefail

# shellcheck source=scripts/demo-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/demo-lib.sh"

demo::parse_args "$@"

demo::header \
  "ForgeHacks —— 容器邊界防禦與映像掃描" \
  "2026-10-03　｜　CCSP Domain 3 / 5" \
  "逃逸鏈從 admission 就被剪斷：非 root、drop ALL、唯讀根檔、不掛 SA token、Trivy 擋高危映像。"

demo::preflight_header
demo::require_cmd kubectl "執行 make bootstrap"
demo::optional_cmd docker "Trivy 走官方映像，需要本機 Docker socket"
demo::require_cluster
demo::require_deploy gateway
demo::require_deploy dataplane

demo::pause

# ---------------------------------------------------------------------------
demo::scene "第一道鎖：命名空間的 Pod Security Admission" \
  "aegis namespace 套用 restricted：root、hostPath、特權容器、保留 capabilities" \
  "在 API Server admission 就被拒，進不到排程器。" \
  "attacker 只降到 baseline，是為了讓攻擊 Pod 起得來，才能展示網路層攔截。"

demo::run "kubectl get ns aegis attacker -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.metadata.labels.pod-security\\.kubernetes\\.io/enforce}{\"\\n\"}{end}'"
demo::assert_contains "restricted" "aegis 命名空間 enforce=restricted"
demo::assert_contains "baseline" "attacker 命名空間 enforce=baseline（讓攻擊模擬跑得起來）"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "試圖部署特權容器：被 admission 擋下" \
  "這不是 NetworkPolicy，連 Pod 物件都建不起來。" \
  "評審要看的是 Denied 與對應的 PSA 理由，不是之後的 DROPPED。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} apply --dry-run=server -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: forge-priv-probe
spec:
  containers:
    - name: x
      image: busybox:1.36
      command: [\"sleep\", \"3600\"]
      securityContext:
        privileged: true
EOF"
demo::assert_fail "特權 Pod 在 restricted 命名空間被 admission 拒絕"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "第二道鎖：容器 securityContext 逐項對攻擊手法" \
  "runAsNonRoot / runAsUser 10001 → RCE 也只拿到無權限使用者。" \
  "allowPrivilegeEscalation=false → no_new_privs，擋住 pkexec 類提權。" \
  "capabilities.drop ALL → 沒有 CAP_SYS_ADMIN，常見逃逸前置條件全斷。" \
  "readOnlyRootFilesystem → 無法落地 webshell。" \
  "automountServiceAccountToken=false → 拿不到進 API Server 的票。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} get deploy/gateway -o jsonpath='{.spec.template.spec.containers[0].securityContext}'"
demo::assert_contains "readOnlyRootFilesystem" "閘道容器根檔唯讀"
demo::assert_contains "allowPrivilegeEscalation" "禁止提權"

demo::run "kubectl -n ${AEGIS_NAMESPACE} get sa gateway-sa -o jsonpath='{.automountServiceAccountToken}'"
demo::assert_contains "false" "gateway-sa 不自動掛載 token"

demo::narrate "" \
  "清單註解寫在 infra/k8s/base/gateway.yaml 檔頭，每一項都對應一種真實逃逸手法。" \
  "資料面同樣套用，只是 uid 改 10002，避免兩個服務共用同一個 Unix 身分。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "執行中的證明：我是誰、根檔能不能寫" \
  "進到正在跑的閘道容器看 uid 與寫入結果。" \
  "預期：uid=10001、寫 /etc 失敗、只能寫掛了 emptyDir 的 /tmp。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} exec deploy/gateway -- id"
demo::assert_contains "10001" "閘道行程以 uid 10001 執行"

demo::run "kubectl -n ${AEGIS_NAMESPACE} exec deploy/gateway -- sh -c 'echo pwned > /etc/pwned' || true"
demo::assert_fail "寫入根檔案系統失敗（唯讀）"

demo::run "kubectl -n ${AEGIS_NAMESPACE} exec deploy/gateway -- sh -c 'echo ok > /tmp/aegis-demo && cat /tmp/aegis-demo'"
demo::assert_contains "ok" "唯一可寫處是有 sizeLimit 的 memory emptyDir"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "第三道鎖：映像供應鏈（Trivy）" \
  "make scan-images 用官方 aquasec/trivy 映像掃 HIGH/CRITICAL，有未修復漏洞就失敗。" \
  "閘道走 distroless 非 root，攻擊面比一般 debug 映像小一個數量級。" \
  "這一幕若本機沒有 Docker 或映像尚未建置，會略過實際掃描、只展示指令。"

demo::show "make scan-images" \
  "完整掃描含建置；現場改跑對已載入映像的 trivy，避免重編五分鐘"
if demo::have docker; then
  demo::run "docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest \\
    image --severity HIGH,CRITICAL --exit-code 0 --ignore-unfixed aegis/gateway:dev"
  demo::assert_ok "Trivy 已對閘道映像跑完 HIGH/CRITICAL 掃描"
else
  demo::verdict skip "本機沒有 Docker，略過 Trivy 實掃"
fi

demo::narrate "" \
  "CI 的 iac / gateway-go workflow 會用 --exit-code 1 把未修復高危當建置失敗。" \
  "Dependabot 每週追六個 ecosystem，補的是「掃得到」之後的「修得掉」。"
demo::pause

# ---------------------------------------------------------------------------
demo::scene "網路層補一刀：就算容器被拿下也打不穿資料面" \
  "容器邊界被突破只是攻擊鏈的第一哩。Cilium L7 只放行 /internal/v1/*。" \
  "Kind 展示關閉 mTLS（ADR 0003），所以這一層靠的是網路身分，不是客戶端憑證。"

demo::run "kubectl -n ${AEGIS_NAMESPACE} debug \\
  \"\$(kubectl -n ${AEGIS_NAMESPACE} get pod -l app.kubernetes.io/name=gateway -o jsonpath='{.items[0].metadata.name}')\" \\
  -q --image=curlimages/curl:8.11.1 -- \\
  curl -sS -m 8 -o /dev/null -w '%{http_code}' \\
  http://dataplane.${AEGIS_NAMESPACE}.svc.cluster.local:8000/docs"
demo::assert_http 403 "FastAPI /docs 被 L7 策略拒絕（不在白名單）"

demo::narrate "" "attacker 命名空間直連 dataplane 的 DROPPED 留給 HackTitan 完整演。"
demo::pause

# ---------------------------------------------------------------------------
demo::rubric "Linux 容器邊界|restricted PSA + 非 root + drop ALL + 唯讀根檔 + 禁止提權。第 2、3、4 幕是可執行證明，不是 YAML 宣言。"
demo::rubric "最小權限身分|ServiceAccount 不掛 token、不開 hostNetwork/PID/IPC，切斷「容器被打下來就進 API Server」這條鏈。"
demo::rubric "供應鏈掃描|Trivy 掃映像與 IaC；CI 對 HIGH/CRITICAL 失敗。第 5 幕現場重跑同一條指令。"
demo::rubric "縱深防禦|容器逃逸被剪斷之後，Cilium L7 仍擋住 /docs 與 /internal/v1/keys。見 threat-model 的橫向移動列。"
demo::rubric "CCSP Domain 3 對照|計算資源安全、映像完整性、特權管理。逐項見 docs/ccsp-mapping.md。"

demo::summary
