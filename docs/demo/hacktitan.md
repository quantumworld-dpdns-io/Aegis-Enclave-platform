# HackTitan 主持稿

**時間**：2027-02  
**腳本**：`./scripts/demo-hacktitan.sh`  
**評分主軸**：IaC、微分段、可觀測性（CCSP Domain 3 / 5）

## 開場（40 秒）

「叢集不是我昨天晚上 click 出來的。Terraform 描述 Kind、Cilium 1.20.1、Prometheus。預設拒絕之後，attacker 命名空間打資料面應該被 eBPF 丟掉，而且 Hubble 與告警都要看得見。有一件事先講清楚：macOS 上我們**關掉** kube-proxy replacement，否則 cilium-agent 會炸。Policy 跟 Hubble 都還在。這是 ADR 0002，`make doctor` 也會唸。」

## 分幕口條

1. **IaC**  
   「node image pin `kindest/node:v1.31.0`，因為 kind provider 落後上游。主機埠綁 127.0.0.1。Grafana 密碼有 validation，不准 admin/password。」

2. **ADR 0002**  
   把 `enable_kube_proxy_replacement` 的 default = false 秀在畫面上。  
   「要完整 Socket LB，用 Linux + cgroup v2，apply `-var ...=true`，然後這座叢集不能再關回去，得 destroy。」

3. **策略清單**  
   「`kubectl get cnp -A`。沒套用就不要假裝有微分段。」

4. **attacker 直連**  
   「這發不該拿到 HTTP 狀態碼，應該逾時或連線被拒。那是 L3/L4。Kind 關 mTLS，所以我們證明的是網路身分。」

5. **Hubble**  
   「`hubble observe --verdict DROPPED`。沒有 CLI 就看 `hubble_drop_total`。關 KPR 不影響這組指標。」

6. **告警**  
   「`AegisCiliumPolicyDropSpike` 加 `AegisAttackerNamespaceTrafficDetected`（零容忍、for: 0m）。兩條一起亮才是偵測加攔截。Grafana 帳密見 README。」

7. **403 vs DROPPED**  
   「閘道 Pod 打 `/internal/v1/keys` 得 403，因為 L7 看得到路徑。attacker 連 TCP 都建不起來。有人問為什麼一個有狀態碼、一個沒有，答案在這一幕。」

## 可能被問

| 問題 | 答 |
| --- | --- |
| 關 KPR 還算 eBPF 嗎？ | CNI 與 NetworkPolicy 仍走 eBPF。少的是 kube-proxy 替換與 Socket LB。ADR 0002。 |
| 為什麼不用 Calico？ | 要 Hubble L7 與同一套 drop 指標。 |
| attacker 流量告警會不會太吵？ | 這個 namespace 在契約裡就是紅隊區，零容忍是設計。生產等價物是「不該互通的 NS 出現流量」。 |

## 收場

指 ccsp-mapping 的 Domain 3 / 5 表。「策略寫在 Git，攔截發生在核心，證據出現在 Prometheus。三件事同時成立才叫做完。」
