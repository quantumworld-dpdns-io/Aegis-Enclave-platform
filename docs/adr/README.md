# 架構決策紀錄

本目錄只記錄「選定後會長期約束實作」的決策。契約細節以 [`../CONTRACT.md`](../CONTRACT.md) 為準；本目錄解釋**為什麼**這樣選。

| 編號 | 標題 | 狀態 |
| --- | --- | --- |
| [0001](0001-split-gateway-dataplane.md) | 閘道與資料面分離 | 已採納 |
| [0002](0002-ebpf-on-macos.md) | macOS 上關閉 Cilium kube-proxy replacement | 已採納 |
| [0003](0003-kind-demo-mtls.md) | Kind 展示關閉閘道 mTLS，正式環境強制開啟 | 已採納 |
| [0004](0004-gateway-pseudonym-subject.md) | 請求主體由閘道假名化並以 X-Aegis-Subject 傳遞 | 已採納 |
| [0005](0005-envelope-encryption.md) | 信封加密與可插拔 KeyProvider | 已採納 |

`make doctor` 在 macOS 上會直接指向 0002。五支 demo 腳本的旁白會引用 0002、0003、0004。
