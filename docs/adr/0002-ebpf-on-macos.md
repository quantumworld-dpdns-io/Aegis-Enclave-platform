# ADR 0002：macOS 上關閉 Cilium kube-proxy replacement

- 狀態：已採納
- 日期：2026-09-13
- 決策者：架構仲裁
- 參照：`infra/terraform/variables.tf` 的 `enable_kube_proxy_replacement`、`scripts/doctor.sh`

## 背景

HackTitan 與 ForgeHacks 都依賴 Cilium NetworkPolicy 與 Hubble。Cilium 1.20.1 的完整資料面（`kubeProxyReplacement` + Socket LB）需要：

1. 宿主機啟用 cgroup v2（unified hierarchy）；
2. Kind 節點容器的 cgroup namespace 與宿主機不同，否則 agent 會掛錯 cgroup root。

開發與多數評審機器是 macOS + Docker Desktop。LinuxKit VM 通常無法同時滿足以上兩點。先前驗證中，開啟 KPR 會讓 `cilium-agent` 反覆 CrashLoopBackOff，`make up` 整段卡死。這是本專案列管的最大環境風險。

`tehcyx/kind` provider 內建的 kind 版本又落後上游，因此 node image 必須由我們 pin，不能再疊一層「預設開啟 KPR」的不確定性。

## 決策

- Terraform 變數 `enable_kube_proxy_replacement` **預設 `false`**。
- 預設組態保留 kube-proxy。Cilium 仍擔任 CNI，NetworkPolicy（L3/L4/L7）與 Hubble（drop / flow / http 指標）完整可用。
- 五支 demo 需要的攔截與觀測全部建立在「非 KPR」路徑上，不把 Socket LB 當展示前提。
- 僅在 Linux 宿主機且 `docker info` 顯示 Cgroup Version 2 時，才允許 `terraform apply -var enable_kube_proxy_replacement=true`。開啟時 Kind 會把 `kubeProxyMode` 設為 `none`；之後不能在同一座叢集把開關關回去，必須 destroy 重建。
- `make doctor` 在 Darwin 上主動警告，並指向本檔。

## 後果

- macOS 上一鍵 `make up` 可預期地成功；微分段 demo 不依賴 KPR。
- 失去 kube-proxy 替換帶來的延遲與 NodePort 優化，本機 demo 可接受。
- 文件必須誠實寫出限制，避免評審以為 Hubble 不能用或策略是假的。
- Linux CI runner（`e2e-kind`）可選擇開啟 KPR 作為加分驗證，但不得成為必過條件，以免與筆電路徑分叉。

## 替代方案

- **預設開啟 KPR**：macOS 開發者與現場評審機器大量失敗，不可接受。
- **強制改用 Lima / Colima / 遠端 Linux**：完整 eBPF 資料面較接近生產，但提高評審重現門檻，只列為進階選項，不當預設。
- **改用 Calico 或其他非 eBPF CNI**：失去 Hubble L7 可視與本專案的比賽敘事。
