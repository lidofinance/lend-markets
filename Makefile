# Shortcuts wrap the foundry commands documented in README/AGENTS.md.
# CI calls a subset of these so local and CI behavior stay in sync.
.DEFAULT_GOAL := help

# Make normally lets an included file replace exported environment variables. Preserve the public inputs so
# precedence is consistently: command line > exported environment > .env > defaults.
DOTENV_OVERRIDE_VARS := PREPARE_MARKETS CONFIG RUN MARKET MARKET_A MARKET_B PIN_BLOCK RPC_URL DEPLOYMENT_RUN \
	FORK_BLOCK TEST_SEED FOUNDRY_FUZZ_SEED ACCEPTANCE_RPC_URL ACCEPTANCE_RUN ACCEPTANCE_PAUSER_COMMITTEE \
	ACCEPTANCE_ENABLE_SETTLEMENT ACCEPTANCE_STEWARD ACCEPTANCE_FEE ACCEPTANCE_MIN_CORE_SEED_SHARES \
	ACCEPTANCE_MIN_VAULT_SEED_SHARES

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

# Keep Make helper definitions out of the environment.
unexport capture_exported_value restore_exported_value

FMT_PATHS := src/LidoLendERC4626.sol src/GuardianSignals.sol src/adapters src/controllers src/interfaces \
	src/oracle src/libs src/periphery src/utils script test

.PHONY: help build sizes test test-local test-fork test-deployment test-simulation test-mutation \
	fmt fmt-check lint coverage snapshot snapshot-diff slither solhint doc ci clean \
	acceptance-run acceptance-run-multi \
	apply-pending pending-stop test-pending

help: ## List commands; deployment details are in script/DEPLOYMENT.md
	@awk 'BEGIN { FS = ":.*## " } /^##@/ { printf "\n%s\n", substr($$0, 5); next } /^[a-z][a-z0-9-]*:.*## / { printf "  %-23s %s\n", $$1, $$2 }' Makefile

##@ Build and tests
build: ## Compile contracts
	forge build

sizes: ## Compile and report contract sizes
	forge build --sizes

test: ## Local + fresh-fork suites; RPC_URL required
	DEPLOYMENT_RUN= PREPARE_MARKETS=false forge test

test-local: ## Local suites; no RPC
	forge test --no-match-path 'test/{fork,deployment}/**'

# Only explicit Make arguments select an existing run or disable its preparation.
test-fork: ## Fork suites: fresh by default; RUN=<run> prepares existing; PREPARE=false only tests
ifeq ($(origin RUN),command line)
	@test -n "$(RUN)" || { echo 'ERROR: RUN must not be empty'; exit 1; }
	@test -n "$(RPC_URL)" || { echo 'ERROR: RPC_URL is required'; exit 1; }
ifeq ($(origin PREPARE),command line)
	@case "$(PREPARE)" in true|false) ;; *) echo 'ERROR: PREPARE must be true or false'; exit 1 ;; esac
	DEPLOYMENT_RUN="$(RUN)" PREPARE_MARKETS="$(PREPARE)" forge test --match-path 'test/fork/**'
else
	DEPLOYMENT_RUN="$(RUN)" PREPARE_MARKETS=true forge test --match-path 'test/fork/**'
endif
else
ifeq ($(origin PREPARE),command line)
	@echo 'ERROR: PREPARE requires an explicit RUN=<run>'; exit 1
endif
	DEPLOYMENT_RUN= PREPARE_MARKETS=false forge test --match-path 'test/fork/**'
endif

test-deployment: ## Solidity deployment scenarios on a Forge fork; RPC_URL, optional FORK_BLOCK
	FOUNDRY_PROFILE=deployment forge test -vv

# The 365-day solvency simulations; the 30-day runs are part of test-local. The gas limit is set in foundry.toml.
test-simulation: ## Year-long solvency simulations
	RUN_SOLVENCY_SIMULATION=true forge test --match-path 'test/simulation/**' -vv

# Local only; never run mutation testing in CI.
test-mutation: ## Mutation testing; requires separate forge >= 1.8.0
	@forge test --help | grep -q -- '--mutate' || { echo "test-mutation: the local forge ($$(forge --version | head -1)) has no mutation testing; it needs forge >= 1.8.0, which is not the pinned .foundryref toolchain (install the .foundryref version)"; exit 1; }
	TEST_SEED=1 forge test --mutate src --match-path 'test/simulation/**' --match-test shortRun --mutation-timeout 900

##@ Formatting and analysis
fmt: ## Format local Solidity paths
	forge fmt $(FMT_PATHS)

fmt-check: ## Check Solidity formatting
	forge fmt --check $(FMT_PATHS)

lint: ## Run Forge lint
	forge lint

coverage: ## Coverage including fresh-fork suites; RPC_URL required
	DEPLOYMENT_RUN= PREPARE_MARKETS=false forge coverage --ir-minimum --report summary

# -vv exposes TEST_SEED and FORK_BLOCK for replay; pin FOUNDRY_FUZZ_SEED for invariant counters too.
snapshot: ## Gas snapshot including fresh-fork suites; RPC_URL required
snapshot-diff: ## Compare snapshot; use the same TEST_SEED
snapshot-diff: SNAP_FLAGS := --diff
snapshot snapshot-diff:
	DEPLOYMENT_RUN= PREPARE_MARKETS=false forge snapshot $(SNAP_FLAGS) -vv

slither: ## Run Slither (separate install)
	slither .

solhint: ## Run Solhint (separate install)
	solhint 'src/**/*.sol'

doc: ## Generate API reference from NatSpec
	forge build --ast
	python3 tools/gen_api_from_artifacts.py

audit-checksums: ## Compare audited source digests; optional REF=<git-ref>
	bash tools/audit-checksums.sh $(REF)

ci: build lint test-local ## Build, lint and local tests

clean: ## Remove Forge build output
	forge clean

RUN ?=
RPC_URL ?=
CONFIG ?= mainnet
MARKET ?= weth-wsteth
PIN_BLOCK ?=
##@ Deployment verification
acceptance-run: ## Verify one market: RUN MARKET RPC_URL
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(MARKET)" || { echo "ERROR: set MARKET"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	ACCEPTANCE_RPC_URL="$(RPC_URL)" ACCEPTANCE_RUN="$(RUN)" MARKET="$(MARKET)" forge test --match-path 'test/acceptance/*' --no-match-contract MultiMarketActivationSimulation -vvv

acceptance-run-multi: ## Verify two markets: RUN MARKET_A MARKET_B RPC_URL
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(MARKET_A)" || { echo "ERROR: set MARKET_A"; exit 1; }
	@test -n "$(MARKET_B)" || { echo "ERROR: set MARKET_B"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	ACCEPTANCE_RPC_URL="$(RPC_URL)" ACCEPTANCE_RUN="$(RUN)" MARKET="$(MARKET_A)" MARKET_A="$(MARKET_A)" MARKET_B="$(MARKET_B)" forge test --match-contract MultiMarketActivationSimulation -vvv

##@ Pending governance action
# Pending multisig action: fork the live network, apply the transaction(s) from
# script/config/<CONFIG>/pending.toml, and leave the fork on :8545 for test-fork / state-mate.
apply-pending: ## Apply pending action on a local fork: CONFIG RPC_URL
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL to the live network's RPC"; exit 1; }
	bash script/pending-action.sh apply "$(CONFIG)" "$(PIN_BLOCK)"

pending-stop: ## Stop the pending-action fork
	bash script/pending-action.sh stop

# Full pre-signing validation: apply the pending action, then run the fork suites against the
# resulting state. RUN selects script/deployment/<run>/Deployment.sol.
test-pending: ## Apply pending action and run fork suites: CONFIG RUN RPC_URL
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	$(MAKE) apply-pending CONFIG="$(CONFIG)" RPC_URL="$(RPC_URL)" PIN_BLOCK="$(PIN_BLOCK)"
	$(MAKE) test-fork RPC_URL=http://127.0.0.1:8545 RUN="$(RUN)" PREPARE=false FORK_BLOCK=
