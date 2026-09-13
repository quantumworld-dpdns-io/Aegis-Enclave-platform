# Aegis-Enclave 統一入口
# 所有日常操作都從這裡走，避免各模組指令散落在 README 各處。

SHELL := /bin/bash
.DEFAULT_GOAL := help

CLUSTER_NAME    ?= aegis-enclave
KUBECONFIG_PATH ?= $(CURDIR)/infra/terraform/kubeconfig
TF_DIR          := infra/terraform
GATEWAY_DIR     := services/gateway
DATAPLANE_DIR   := services/dataplane
CONTRACTS_DIR   := contracts

GATEWAY_IMAGE   ?= aegis/gateway:dev
DATAPLANE_IMAGE ?= aegis/dataplane:dev

# Trivy 與 Slither 走官方映像，避免在本機裝一堆掃描工具。
TRIVY   := docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v $(HOME)/.cache/trivy:/root/.cache/ aquasec/trivy:latest
SLITHER := docker run --rm -v $(CURDIR)/$(CONTRACTS_DIR):/src trailofbits/eth-security-toolbox:latest

export KUBECONFIG := $(KUBECONFIG_PATH)

##@ 說明

.PHONY: help
help: ## 顯示所有可用指令
	@awk 'BEGIN {FS = ":.*##"; printf "\nAegis-Enclave\n用法: make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""

##@ 環境準備

.PHONY: bootstrap
bootstrap: ## 安裝缺少的工具鏈 (kind/helm/cilium/foundry/uv)
	./scripts/bootstrap.sh

.PHONY: doctor
doctor: ## 檢查本機環境是否具備執行條件
	./scripts/doctor.sh

##@ 叢集生命週期

.PHONY: up
up: images ## 一鍵拉起 Kind 叢集 + Cilium + 可觀測性 + 應用程式
	cd $(TF_DIR) && terraform init -upgrade && terraform apply -auto-approve
	$(MAKE) deploy

.PHONY: down
down: ## 銷毀整座叢集
	cd $(TF_DIR) && terraform destroy -auto-approve || kind delete cluster --name $(CLUSTER_NAME)

.PHONY: deploy
deploy: ## 部署應用程式與 Cilium 網路策略到既有叢集
	kubectl apply -k infra/k8s/base
	kubectl apply -f infra/k8s/policies/
	kubectl -n aegis rollout status deploy/gateway --timeout=180s
	kubectl -n aegis rollout status deploy/dataplane --timeout=180s

.PHONY: images
images: ## 建置容器映像並載入 Kind
	docker build -t $(GATEWAY_IMAGE) $(GATEWAY_DIR)
	docker build -t $(DATAPLANE_IMAGE) $(DATAPLANE_DIR)

.PHONY: load
load: images ## 將映像載入既有的 Kind 叢集
	kind load docker-image $(GATEWAY_IMAGE) --name $(CLUSTER_NAME)
	kind load docker-image $(DATAPLANE_IMAGE) --name $(CLUSTER_NAME)

##@ 測試

.PHONY: test
test: test-contracts test-gateway test-dataplane ## 跑所有模組的測試

.PHONY: test-contracts
test-contracts: ## Foundry 單元 / fuzz / invariant 測試
	cd $(CONTRACTS_DIR) && forge test -vv

.PHONY: coverage-contracts
coverage-contracts: ## 產出 Solidity 覆蓋率 (lcov)
	cd $(CONTRACTS_DIR) && forge coverage --report lcov --report-file lcov.info --report summary

.PHONY: test-gateway
test-gateway: ## Go 閘道單元測試
	cd $(GATEWAY_DIR) && go test ./... -race -cover

.PHONY: test-dataplane
test-dataplane: ## Python 資料面測試（含三個 KeyProvider 的合約測試）
	cd $(DATAPLANE_DIR) && uv run pytest -v --cov=app --cov-report=term-missing

##@ 安全掃描

.PHONY: scan
scan: scan-images scan-contracts scan-iac ## 執行所有安全掃描

.PHONY: scan-images
scan-images: images ## Trivy 掃描容器映像 (CRITICAL/HIGH 視為失敗)
	$(TRIVY) image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed $(GATEWAY_IMAGE)
	$(TRIVY) image --severity HIGH,CRITICAL --exit-code 1 --ignore-unfixed $(DATAPLANE_IMAGE)

.PHONY: scan-contracts
scan-contracts: ## Slither 靜態分析智能合約
	$(SLITHER) slither /src --config-file /src/slither.config.json

.PHONY: scan-iac
scan-iac: ## Trivy 掃描 Terraform 與 Kubernetes 設定的錯誤組態
	$(TRIVY) config --severity HIGH,CRITICAL --exit-code 1 $(TF_DIR)
	$(TRIVY) config --severity HIGH,CRITICAL --exit-code 1 infra/k8s

##@ 展示腳本（各賽事）

.PHONY: demo-tln
demo-tln: ## TLN: 零信任閘道 + 威脅攔截 + SIEM 日誌審計
	./scripts/demo-tln.sh

.PHONY: demo-fincyber
demo-fincyber: ## Financial Cybersecurity: PII 遮罩 + KMS 金鑰生命週期
	./scripts/demo-fincyber.sh

.PHONY: demo-forgehacks
demo-forgehacks: ## ForgeHacks: 容器邊界防禦 + Trivy 掃描管線
	./scripts/demo-forgehacks.sh

.PHONY: demo-climatechain
demo-climatechain: ## IEEE ClimateChain: 碳權合約 + Foundry + Slither 審計
	./scripts/demo-climatechain.sh

.PHONY: demo-hacktitan
demo-hacktitan: ## HackTitan: Terraform IaC + Cilium 微分段 + Grafana 觀測
	./scripts/demo-hacktitan.sh

##@ 工具

.PHONY: hubble
hubble: ## 開啟 Hubble UI 觀察即時流量與策略攔截
	cilium hubble port-forward &
	hubble observe --follow --verdict DROPPED

.PHONY: grafana
grafana: ## 連接埠轉發 Grafana (預設帳密見 docs/demo/README.md)
	kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80

.PHONY: fmt
fmt: ## 格式化所有語言的程式碼
	cd $(GATEWAY_DIR) && go fmt ./...
	cd $(DATAPLANE_DIR) && uv run ruff format app tests && uv run ruff check --fix app tests
	cd $(CONTRACTS_DIR) && forge fmt
	cd $(TF_DIR) && terraform fmt -recursive

.PHONY: clean
clean: ## 清除建置產出
	rm -rf $(CONTRACTS_DIR)/out $(CONTRACTS_DIR)/cache $(GATEWAY_DIR)/bin reports
