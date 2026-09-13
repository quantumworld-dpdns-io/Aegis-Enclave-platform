# 賽事展示說明

七個模組共用同一座叢集。每場比賽只換腳本與這份目錄裡的主持稿，程式碼不重寫。

| 賽事 | 腳本 | 主持稿 | 一句話 |
| --- | --- | --- | --- |
| TLN | `scripts/demo-tln.sh` | [tln.md](tln.md) | 無效 JWT、演算法混淆、稽核與 SIEM |
| FinCyber | `scripts/demo-fincyber.sh` | [fincyber.md](fincyber.md) | 信封加密、遮罩、金鑰生命週期 |
| ForgeHacks | `scripts/demo-forgehacks.sh` | [forgehacks.md](forgehacks.md) | PSA、securityContext、Trivy |
| ClimateChain | `scripts/demo-climatechain.sh` | [climatechain.md](climatechain.md) | Foundry + Slither + 防雙花 |
| HackTitan | `scripts/demo-hacktitan.sh` | [hacktitan.md](hacktitan.md) | Terraform、微分段、Hubble |

## 怎麼跑

```bash
make doctor          # 含 macOS eBPF / KPR 提醒（ADR 0002）
make up              # 有叢集的四場需要；ClimateChain 前半段不需要
./scripts/demo-tln.sh --dry-run    # 預演：只印指令，CI 也用這個
./scripts/demo-tln.sh              # 實際打叢集
./scripts/demo-tln.sh --interactive
```

五支都支援 `--dry-run`、`--interactive`、`--max-lines N`。`--dry-run` 結束碼為 0 即表示腳本可解析、分幕完整。判定在預演模式會標「略過」，這是預期行為。

## 三條現場一定要講的裁定

1. **Kind 的 `AEGIS_REQUIRE_MTLS=false`**。沒有 Ingress，8080 是明文 HTTP。TLN 打的是偽造 JWT 與 alg confusion，不是客戶端憑證。正式環境必須開 mTLS。[ADR 0003](../adr/0003-kind-demo-mtls.md)
2. **`subject` 由閘道用 `AEGIS_PSEUDONYM_SALT` 產生**，經 `X-Aegis-Subject` 傳給資料面。日誌裡只會看到 `sub_` 開頭的假名。[ADR 0004](../adr/0004-gateway-pseudonym-subject.md)
3. **macOS 預設關閉 Cilium KPR**。NetworkPolicy 與 Hubble 仍可用。有人問「eBPF 是不是假的」就指 ADR 0002。[ADR 0002](../adr/0002-ebpf-on-macos.md)

## demo 素材

腳本預設讀 `.demo/`（已被 gitignore）。Kind 路徑**不需要**用戶端憑證；正式環境的 PKI 仍可放在 `.demo/pki/` 供旁白對照。

```text
.demo/
├── pki/                      # 可選。正式環境 mTLS 才用
│   ├── ca.crt
│   ├── client-analyst.crt
│   └── client-analyst.key
└── tokens/
    ├── analyst.jwt           # 合法 RS256，iss=https://aegis.local aud=aegis-gateway
    ├── attack-alg-none.jwt   # header.alg = none
    └── attack-alg-hs256.jwt  # 用 JWKS 公鑰當 HMAC 密鑰簽的 HS256
```

產生方式（在已有模組 B 測試金鑰之後）：

```bash
mkdir -p .demo/tokens
# 用閘道 testdata 的 RSA 私鑰簽 analyst.jwt
# 攻擊 token 見 services/gateway 的 TestRejectAlgConfusion 夾具
# 若尚未合併模組 B，先放三個佔位檔讓 --dry-run 以外的前置檢查能對到路徑
```

私鑰與 salt **不准**進版控。`.env`、`.demo/` 都已在 gitignore。

## Grafana（本機 Kind）

```bash
make grafana
# http://127.0.0.1:3000
# 使用者 admin
# 密碼預設為 Terraform 變數 grafana_admin_password（長度 ≥ 12，預設 aegis-demo-not-for-prod）
```

這個密碼只准用在本機。儀表板名稱以實際 JSON 為準，主持稿寫的是「Aegis Zero-Trust SIEM / 資料保護 / 微分段」三張。

## 現場節奏建議

- 先 `--dry-run` 過一遍，確認分幕與旁白順序。
- 正式跑之前再 `make doctor`。Docker 記憶體建議 ≥ 8 GB。
- 一場 10–12 分鐘：開場 1 分鐘講裁定，中間 8 分鐘跑腳本，留 2 分鐘給「為什麼 Kind 不開 mTLS / 為什麼關 KPR」。
- 腳本失敗不會中止（見 `demo-lib.sh`）。把「略過」當成降級，不要當場 `exit 1` 黑畫面。
