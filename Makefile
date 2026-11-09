# Shortcuts wrap the foundry commands documented in README/AGENTS.md.
# CI calls a subset of these so local and CI behavior stay in sync.
.DEFAULT_GOAL := help

# Make normally lets an included file replace exported environment variables. Preserve the public inputs so
# precedence is consistently: command line > exported environment > .env > defaults.
DOTENV_OVERRIDE_VARS := SCRIPT ARTIFACTS_CONFIG ACTIVATION_ENTRYPOINT PREPARE_MARKETS CONFIG RUN MARKET MARKET_A MARKET_B PIN_BLOCK RPC_URL DEPLOYER_ACCOUNT DEPLOYER_SENDER ETHERSCAN_API_KEY VERIFY RESUME EXECUTOR ARTIFACTS_DIR \
	FORK_BLOCK TEST_SEED FOUNDRY_FUZZ_SEED ACCEPTANCE_RPC_URL ACCEPTANCE_REGISTRY ACCEPTANCE_PAUSER_COMMITTEE \
	ACCEPTANCE_ENABLE_SETTLEMENT

define capture_exported_value
_DOTENV_ORIGIN_$(1) := $$(origin $(1))
_DOTENV_VALUE_$(1) := $$(value $(1))
endef
$(foreach variable,$(DOTENV_OVERRIDE_VARS),$(eval $(call capture_exported_value,$(variable))))

-include .env

define restore_exported_value
ifneq ($$(filter environment%,$$(_DOTENV_ORIGIN_$(1))),)
$(1) := $$(_DOTENV_VALUE_$(1))
endif
endef
$(foreach variable,$(DOTENV_OVERRIDE_VARS),$(eval $(call restore_exported_value,$(variable))))

export
unexport DOTENV_OVERRIDE_VARS
unexport $(addprefix _DOTENV_ORIGIN_,$(DOTENV_OVERRIDE_VARS))
unexport $(addprefix _DOTENV_VALUE_,$(DOTENV_OVERRIDE_VARS))

# Avoid evaluating legacy TOML defaults while exporting the environment.
unexport capture_exported_value restore_exported_value
unexport $(foreach variable,EXECUTOR,$(if $(filter undefined,$(origin $(variable))),$(variable)))

FMT_PATHS := src/LidoLendERC4626.sol src/GuardianSignals.sol src/adapters src/controllers src/interfaces \
	src/oracle src/libs src/periphery src/utils script test

.PHONY: help build sizes test test-local test-fork test-deployment test-simulation test-mutation \
	deploy-script record-deployment export-deployment fmt fmt-check lint coverage snapshot snapshot-diff slither solhint doc ci clean \
	activate-markets fork-activate state-mate-config acceptance-run acceptance-run-multi \
	apply-pending pending-stop test-pending

help: ## List commands; deployment details are in script/DEPLOYMENT.md
	@awk 'BEGIN { FS = ":.*## " } /^##@/ { printf "\n%s\n", substr($$0, 5); next } /^[a-z][a-z0-9-]*:.*## / { printf "  %-23s %s\n", $$1, $$2 }' Makefile

##@ Build and tests
build: ## Compile contracts
	forge build

sizes: ## Compile and report contract sizes
	forge build --sizes

test: ## Local + fresh-fork suites; RPC_URL required
	ARTIFACTS_DIR= PREPARE_MARKETS=false forge test

test-local: ## Local suites; no RPC
	forge test --no-match-path 'test/{fork,deployment}/**'

# Only explicit Make arguments select an existing run or disable its preparation.
test-fork: ## Fork suites: fresh by default; RUN=<run> prepares existing; PREPARE=false only tests
ifeq ($(origin RUN),command line)
	@test -n "$(RUN)" || { echo 'ERROR: RUN must not be empty'; exit 1; }
	@test -n "$(RPC_URL)" || { echo 'ERROR: RPC_URL is required'; exit 1; }
ifeq ($(origin PREPARE),command line)
	@case "$(PREPARE)" in true|false) ;; *) echo 'ERROR: PREPARE must be true or false'; exit 1 ;; esac
	ARTIFACTS_DIR="$(RUN)" PREPARE_MARKETS="$(PREPARE)" forge test --match-path 'test/fork/**'
else
	ARTIFACTS_DIR="$(RUN)" PREPARE_MARKETS=true forge test --match-path 'test/fork/**'
endif
else
ifeq ($(origin PREPARE),command line)
	@echo 'ERROR: PREPARE requires an explicit RUN=<run>'; exit 1
endif
	ARTIFACTS_DIR= PREPARE_MARKETS=false forge test --match-path 'test/fork/**'
endif

test-deployment: ## Solidity deployment scenarios on a Forge fork; RPC_URL, optional FORK_BLOCK
	FOUNDRY_PROFILE=deployment forge test -vv

# The 365-day solvency simulations; the 30-day runs are part of test-local. The gas limit is set in foundry.toml.
test-simulation: ## Year-long solvency simulations
	RUN_SOLVENCY_SIMULATION=true forge test --match-path 'test/simulation/**' -vv

# Outside the pinned toolchain; isolate-mode gas differs. See AGENTS.md before comparing runs.
test-mutation: ## Mutation testing; requires separate forge >= 1.8.0
	@forge test --help | grep -q -- '--mutate' || { echo "test-mutation: the local forge ($$(forge --version | head -1)) has no mutation testing; it needs forge >= 1.8.0, which is not the pinned .foundryref toolchain (install it separately, e.g. foundryup -i v1.8.3)"; exit 1; }
	TEST_SEED=1 forge test --mutate src --match-path 'test/simulation/**' --match-test shortRun --mutation-timeout 900

##@ Formatting and analysis
fmt: ## Format local Solidity paths
	forge fmt $(FMT_PATHS)

fmt-check: ## Check Solidity formatting
	forge fmt --check $(FMT_PATHS)

lint: ## Run Forge lint
	forge lint

coverage: ## Coverage including fresh-fork suites; RPC_URL required
	ARTIFACTS_DIR= PREPARE_MARKETS=false forge coverage --ir-minimum --report summary

# -vv exposes TEST_SEED and FORK_BLOCK for replay; pin FOUNDRY_FUZZ_SEED for invariant counters too.
snapshot: ## Gas snapshot including fresh-fork suites; RPC_URL required
snapshot-diff: ## Compare snapshot; use the same TEST_SEED
snapshot-diff: SNAP_FLAGS := --diff
snapshot snapshot-diff:
	ARTIFACTS_DIR= PREPARE_MARKETS=false forge snapshot $(SNAP_FLAGS) -vv

slither: ## Run Slither (separate install)
	slither .

solhint: ## Run Solhint (separate install)
	solhint 'src/**/*.sol'

doc: ## Generate API reference from NatSpec
	forge build --ast
	python3 tools/gen_api_from_artifacts.py

ci: build lint test-local ## Build, lint and local tests

clean: ## Remove Forge build output
	forge clean

##@ Solidity deployment
RUN ?=
RPC_URL ?=
DEPLOYER_ACCOUNT ?=
DEPLOYER_SENDER ?=
VERIFY ?= false
RESUME ?= false

# Broadcasting is opt-in on the command line; an old .env cannot submit transactions.
deploy-script: ## SCRIPT=<path.s.sol>; simulate by default, BROADCAST=true RUN=<run> to deploy and record
	@test -n "$(SCRIPT)" || { echo 'SCRIPT is required'; exit 1; }
	@test -n "$(RPC_URL)" || { echo 'RPC_URL is required'; exit 1; }
	@case "$(VERIFY):$(RESUME)" in true:true|true:false|false:true|false:false) ;; *) echo 'VERIFY and RESUME must be true or false'; exit 1 ;; esac
ifeq ($(origin BROADCAST),command line)
	@case "$(BROADCAST)" in true|false) ;; *) echo 'BROADCAST must be true or false'; exit 1 ;; esac
endif
ifeq ($(origin BROADCAST):$(BROADCAST),command line:true)
	@test -n "$(RUN)" || { echo 'RUN is required for broadcast'; exit 1; }
	@test -n "$(DEPLOYER_SENDER)" || { echo 'DEPLOYER_SENDER is required for broadcast'; exit 1; }
	@test "$(VERIFY)" = false || test -n "$(ETHERSCAN_API_KEY)" || { echo 'ETHERSCAN_API_KEY is required for verification'; exit 1; }
	@forge build --skip test
	@DEPLOYMENT_RUN="$(RUN)" forge script "$(SCRIPT)" --rpc-url "$(RPC_URL)" \
		--sender "$(DEPLOYER_SENDER)" $(if $(DEPLOYER_ACCOUNT),--account "$(DEPLOYER_ACCOUNT)",--unlocked) \
		--broadcast $(if $(filter true,$(VERIFY)),--verify,) $(if $(filter true,$(RESUME)),--resume,) -vv
	$(MAKE) record-deployment SCRIPT="$(SCRIPT)" RUN="$(RUN)"
else
	@test "$(RESUME)" = false || { echo 'RESUME requires BROADCAST=true'; exit 1; }
	@test "$(VERIFY)" = false || { echo 'VERIFY requires BROADCAST=true'; exit 1; }
	@forge build --skip test
	@DEPLOYMENT_RUN= forge script "$(SCRIPT)" --rpc-url "$(RPC_URL)" $(if $(DEPLOYER_SENDER),--sender "$(DEPLOYER_SENDER)",) -vv
endif

record-deployment: ## Validate and record a completed broadcast: SCRIPT RUN RPC_URL
	@test -n "$(RUN)" -a -n "$(SCRIPT)" -a -n "$(RPC_URL)" || { echo 'SCRIPT, RUN and RPC_URL are required'; exit 1; }
	@forge script script/deployment/RecordDeployment.s.sol --rpc-url "$(RPC_URL)" \
		--sig 'run(string,string)' "$(RUN)" "$(SCRIPT)"

export-deployment: ## Export address provider: SCRIPT=<export.s.sol> RUN=<run>
	@test -n "$(RUN)" || { echo 'RUN is required'; exit 1; }
	@test -n "$(SCRIPT)" || { echo 'SCRIPT is required'; exit 1; }
	forge script "$(SCRIPT)" --sig 'run(string)' "$(RUN)"
	forge fmt "script/deployment/generated/$(RUN)"

CONFIG ?= mainnet
MARKET ?= weth-wsteth
PIN_BLOCK ?=
ACTIVATION_ENTRYPOINT ?= run()
EXECUTOR ?= $(shell if [ -n "$(RUN)" ] && [ -f "deployed/$(RUN)/protocol.toml" ]; then \
	awk -F= '/^[[:space:]]*evm_script_executor[[:space:]]*=/{gsub(/[[:space:]\"]/, "", $$2); print $$2; exit}' "deployed/$(RUN)/protocol.toml"; \
	fi)
DEPLOY_ENV = ARTIFACTS_DIR="$(RUN)"

##@ Artifact verification and fork activation
# Fork only: fund and impersonate the EVMScriptExecutor on the local node, then replay the activation motion
# for every market in the run. Markets must be activated before the fork suites can bind them.
fork-activate: ## Historical TOML run: impersonate executor and activate on Anvil
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL (the local node)"; exit 1; }
	@test -n "$(EXECUTOR)" || { echo "ERROR: could not read evm_script_executor from deployed/$(RUN)/protocol.toml"; exit 1; }
	@cast rpc anvil_setBalance "$(EXECUTOR)" 0x8AC7230489E80000 --rpc-url "$(RPC_URL)" >/dev/null \
	  || { echo "ERROR: $(RPC_URL) is not an Anvil node (anvil_setBalance failed)"; exit 1; }
	@cast rpc anvil_impersonateAccount "$(EXECUTOR)" --rpc-url "$(RPC_URL)" >/dev/null \
	  || { echo "ERROR: cannot impersonate $(EXECUTOR)"; exit 1; }
	$(MAKE) activate-markets RUN="$(RUN)" RPC_URL="$(RPC_URL)"

activate-markets: ## Historical TOML run: replay activation as unlocked executor on Anvil
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	@test -n "$(EXECUTOR)" || { echo "ERROR: could not read evm_script_executor from deployed/$(RUN)/protocol.toml"; exit 1; }
	@$(DEPLOY_ENV) forge script script/ActivateMarkets.s.sol --sig '$(ACTIVATION_ENTRYPOINT)' \
		--rpc-url "$(RPC_URL)" --unlocked --sender "$(EXECUTOR)" --broadcast

# state-mate configs for RUN: addresses from its artifacts, expectations from script/config/$(CONFIG)/, proxy
# implementations from the node at RPC_URL. Written into script/config/$(CONFIG)/state-mate/.
state-mate-config: ## Historical TOML run: generate state-mate config; CONFIG RUN RPC_URL
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL (the node the run lives on)"; exit 1; }
	RUN="$(RUN)" CONFIG="$(CONFIG)" RPC_URL="$(RPC_URL)" python3 tools/gen_state_mate.py

acceptance-run: ## Verify one market: RUN MARKET RPC_URL
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(MARKET)" || { echo "ERROR: set MARKET"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	ACCEPTANCE_RPC_URL="$(RPC_URL)" ACCEPTANCE_REGISTRY="deployed/$(RUN)/protocol.toml" MARKET="$(MARKET)" forge test --match-path 'test/acceptance/*' --no-match-contract MultiMarketActivationSimulation -vvv

acceptance-run-multi: ## Verify two markets: RUN MARKET_A MARKET_B RPC_URL
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(MARKET_A)" || { echo "ERROR: set MARKET_A"; exit 1; }
	@test -n "$(MARKET_B)" || { echo "ERROR: set MARKET_B"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	ACCEPTANCE_RPC_URL="$(RPC_URL)" ACCEPTANCE_REGISTRY="deployed/$(RUN)/protocol.toml" MARKET="$(MARKET_A)" MARKET_A="$(MARKET_A)" MARKET_B="$(MARKET_B)" forge test --match-contract MultiMarketActivationSimulation -vvv

##@ Pending governance action
# Pending multisig action: fork the live network, apply the transaction(s) from
# script/config/<CONFIG>/pending.toml, and leave the fork on :8545 for test-fork / state-mate.
apply-pending: ## Apply pending action on a local fork: CONFIG RPC_URL
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL to the live network's RPC"; exit 1; }
	bash script/pending-action.sh apply "$(CONFIG)" "$(PIN_BLOCK)"

pending-stop: ## Stop the pending-action fork
	bash script/pending-action.sh stop

# Full pre-signing validation: apply the pending action, then run the fork suites against the
# resulting state. RUN names the live run's artifacts under deployed/<run>/.
test-pending: ## Apply pending action and run fork suites: CONFIG RUN RPC_URL
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	$(MAKE) apply-pending CONFIG="$(CONFIG)" RPC_URL="$(RPC_URL)" PIN_BLOCK="$(PIN_BLOCK)"
	$(MAKE) test-fork RPC_URL=http://127.0.0.1:8545 RUN="$(RUN)" PREPARE=false FORK_BLOCK=
