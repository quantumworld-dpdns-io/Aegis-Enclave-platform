# IEEE ClimateChain 主持稿

**時間**：2026-10-05  
**腳本**：`./scripts/demo-climatechain.sh`  
**評分主軸**：碳權合約正確性、測試深度、靜態分析（CCSP Domain 4）

## 開場（30 秒）

「碳權上鏈不是把數字寫進 mapping 就結束。我們要證明：退役不能雙花、隨機輸入也守不變量、Slither 進 Code Scanning。這一場前半不需要 Kubernetes；評審筆電沒有 Docker Desktop 也能看 forge test。」

## 分幕口條

1. **介面**  
   「ERC-1155，`projectId` 區分專案。`retire` 銷毀並寫入 RetirementRegistry。dataplane 只認 `CreditsMinted` / `CreditsRetired`，不掃整條鏈。ABI 鎖在契約第 7 節。」

2. **單元測試**  
   「`deny_warnings=true`，警告當失敗。先跑非 invariant，控制現場時間。」

3. **模糊與不變量**  
   「handler 已 bound 輸入，`fail_on_revert=true`：隨機呼叫 revert 就是缺陷。CI profile 會把 runs 拉到一萬，現場用 512。」

4. **覆蓋率**  
   「看 retire / mint / 權限修飾子有沒有綠，不要跟評審比小數點。」

5. **Slither**  
   「容器跑，跟 CI 同一套 toolbox。重入、任意寫、未檢查回傳值。沒有 Docker 就指 GitHub Code Scanning 的 SARIF。」

6. **deployments/local.json**  
   「位址禁止手抄進 YAML。沒部署過就誠實略過。」

7. **經閘道退役（可選）**  
   「合約對還不夠。analyst 在應用層拿 403。零信任是合約的門，不是可選配件。Kind 不開 mTLS，講一句 ADR 0003。」

## 可能被問

| 問題 | 答 |
| --- | --- |
| 為什麼不是 ERC-20？ | 多專案碳權用 ERC-1155 一個合約多 id，退役量按 project 計。 |
| 有沒有主網？ | 沒有。Anvil 31337。MEV 與跨鏈橋不在範圍，威脅模型寫了。 |
| invariant 會不會太慢？ | 現場預設深度 64；要看狠的把 `FOUNDRY_PROFILE=ci` 留給 CI。 |

## 收場

「高價值資產的正確性是測出來的，不是白皮書寫出來的。閘道那一刀是為了證明：鏈上對、應用層錯，仍然不該過。」
