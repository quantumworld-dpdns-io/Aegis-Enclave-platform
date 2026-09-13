# ForgeHacks 主持稿

**時間**：2026-10-03  
**腳本**：`./scripts/demo-forgehacks.sh`  
**評分主軸**：Linux 容器邊界、映像掃描、最小權限（CCSP Domain 3）

## 開場（30 秒）

「網路策略是第二道。第一道是：惡意 Pod 根本進不了 `aegis` 命名空間。我們用 admission 擋特權、用 securityContext 剪逃逸鏈、用 Trivy 擋髒映像。就算 RCE 成功，你也只是 uid 10001，根檔不能寫，旁邊沒有 ServiceAccount token。」

## 分幕口條

1. **PSA**  
   「`aegis` = restricted，`attacker` = baseline。attacker 不是因為我們心軟，是因為攻擊 Pod 起不來就沒有後面的 Hubble 故事。」

2. **特權 Pod dry-run**  
   「`kubectl apply --dry-run=server` 就會 Denied。這時候還沒有 CNI 的事。」

3. **securityContext 對照表**  
   對著 `gateway.yaml` 檔頭唸五項：非 root、no_new_privs、drop ALL、唯讀根檔、不掛 token。資料面 uid 10002，兩個服務不共用 Unix 身分。

4. **exec 證明**  
   「`id` 是 10001。寫 `/etc/pwned` 失敗。`/tmp` 是有 sizeLimit 的 memory emptyDir，避免把節點記憶體寫爆。」

5. **Trivy**  
   「官方映像掃，版本跟 CI 一樣。HIGH/CRITICAL 未修復就讓 pipeline 紅。現場若沒有映像，略過實掃、改指 workflow。」

6. **L7 補一刀**  
   「容器被拿下仍打不開 `/docs`。Kind 不開 mTLS，所以這層靠 Cilium 身分。attacker 直連留給 HackTitan。」

## 可能被問

| 問題 | 答 |
| --- | --- |
| distroless 還能 kubectl exec sh？ | 展示用 dev 映像可能仍有 shell；生產應為無 shell。若 exec 失敗，改唸 Dockerfile 的 `USER` 與 distroless base。 |
| 為什麼不用 gVisor / Kata？ | Kind + Docker Desktop 相容性差，超出比賽重現範圍。我們把可攜的控制項做滿。 |
| drop ALL 會不會害 Cilium 失效？ | Cilium 跑在自己的 DaemonSet，不是應用容器。應用不需要 CAP_NET_ADMIN。 |

## 收場

回到「逃逸鏈從 admission 被剪斷」。若時間夠，打開威脅模型「供應鏈與主機」表，讓評審看到每一列都有幕次。
