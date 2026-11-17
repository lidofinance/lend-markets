# Shortcuts wrap the foundry commands documented in README/AGENTS.md.
# CI calls a subset of these so local and CI behavior stay in sync.
.DEFAULT_GOAL := help

# Make normally lets an included file replace exported environment variables. Preserve the public inputs so
# precedence is consistently: command line > exported environment > .env > defaults.
DOTENV_OVERRIDE_VARS := SCRIPT DEPLOYER_SENDER DEPLOYER_ACCOUNT PREPARE_MARKETS CONFIG RUN MARKET MARKET_A MARKET_B PIN_BLOCK RPC_URL DEPLOYMENT_RUN \
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

DEPLOYMENT_ANCHORS := script/Bundler3Anchor.sol script/CircuitBreakerAnchor.sol script/VaultV2Anchor.sol

.PHONY: help build build-deps sizes deploy test test-local test-fork test-deployment test-simulation test-mutation \
	fmt fmt-check lint coverage snapshot snapshot-diff slither solhint doc test-plan test-plan-check audit-checksums ci clean \
	acceptance-run acceptance-run-multi \
	apply-pending pending-stop test-pending

help: ## List commands and their inputs
	@echo 'Build and checks:'
	@echo '  build                forge build (contracts, scripts and tests)'
	@echo '  sizes                deployed-contract sizes; excludes test and deployment harnesses'
	@echo '  fmt / fmt-check      format local Solidity / check formatting'
	@echo '  lint                 forge lint'
	@echo '  clean                remove Forge build output'
	@echo ''
	@echo 'Deployment (one script):'
	@echo '  deploy SCRIPT=<path.s.sol> RPC_URL=<rpc> DEPLOYER_SENDER=<address>'
	@echo '                       builds and simulates; parameters and output paths come from the Solidity recipe'
	@echo '                       add BROADCAST=true DEPLOYER_ACCOUNT=<keystore> to send transactions'
	@echo '                       BROADCAST must be on the command line; environment/.env cannot enable it'
	@echo '                       verification and resume: direct forge options, see script/DEPLOYMENT.md'
	@echo ''
	@echo 'Tests:'
	@echo '  test                 local + fresh mainnet-fork suites; RPC_URL required'
	@echo '  test-local           unit, scenario, invariant and 30-day simulations; no RPC'
	@echo '  test-fork RPC_URL=<rpc>                         fresh mainnet fixture inside Forge'
	@echo '  test-fork RUN=<run> RPC_URL=<rpc>               prepare missing/inert markets on a private fork'
	@echo '  test-fork RUN=<run> PREPARE=false RPC_URL=<rpc>  check recorded state without preparation'
	@echo '                       RUN/PREPARE are command-line selectors; optional FORK_BLOCK pins the fork'
	@echo '  test-deployment      Solidity deployment scenarios; RPC_URL, optional FORK_BLOCK'
	@echo '  test-simulation      365-day solvency simulations'
	@echo '  test-mutation        local mutation testing of src/; requires forge >= 1.8.0'
	@echo '  acceptance-run       RUN=<run> MARKET=<market> RPC_URL=<rpc>'
	@echo '  acceptance-run-multi RUN=<run> MARKET_A=<a> MARKET_B=<b> RPC_URL=<rpc>'
	@echo '                       reviewed ACCEPTANCE_* inputs are listed in script/DEPLOYMENT.md'
	@echo '  ci                   build + lint + test-local'
	@echo ''
	@echo 'Reports and documentation:'
	@echo '  coverage             coverage including fresh-fork suites; RPC_URL required'
	@echo '  snapshot             gas snapshot including fork suites; RPC_URL required'
	@echo '  snapshot-diff        compare with .gas-snapshot; use the same TEST_SEED and FORK_BLOCK'
	@echo '  doc                  regenerate docs/specs/api/ from NatSpec'
	@echo '  test-plan            update TEST_PLAN.md file, test and contract-member links'
	@echo '  test-plan-check      check TEST_PLAN.md links and test references'
	@echo '  audit-checksums      audited-source digests; optional REF=<git-ref>'
	@echo '  slither / solhint    optional analyzers; require separate installation'
	@echo ''
	@echo 'Pending governance:'
	@echo '  apply-pending        CONFIG=<config> RPC_URL=<rpc> [PIN_BLOCK=<block>]; apply on local Anvil'
	@echo '  test-pending         CONFIG=<config> RUN=<run> RPC_URL=<rpc>; apply then test without preparation'
	@echo '  pending-stop         stop the pending-action Anvil fork'

##@ Deployment
deploy: ## One script: SCRIPT RPC_URL DEPLOYER_SENDER; BROADCAST=true DEPLOYER_ACCOUNT=<keystore> to send
	@test -n "$(SCRIPT)" && test -f "$(SCRIPT)" || { echo 'ERROR: set SCRIPT to an existing .s.sol file'; exit 1; }
	@test -n "$(RPC_URL)" || { echo 'ERROR: RPC_URL is required'; exit 1; }
	@test -n "$(DEPLOYER_SENDER)" || { echo 'ERROR: DEPLOYER_SENDER is required'; exit 1; }
	@set -eu; set --; \
	if [ "$(origin BROADCAST)" = 'command line' ]; then \
	  case "$(BROADCAST)" in \
	    true) test -n "$(DEPLOYER_ACCOUNT)" || { echo 'ERROR: DEPLOYER_ACCOUNT is required for broadcast'; exit 1; }; \
	          set -- --account "$(DEPLOYER_ACCOUNT)" --broadcast ;; \
	    false) ;; \
	    *) echo 'ERROR: BROADCAST must be true or false'; exit 1 ;; \
	  esac; \
	fi; \
	forge build; \
	forge script "$(SCRIPT)" --rpc-url "$(RPC_URL)" --sender "$(DEPLOYER_SENDER)" "$$@"

##@ Build and tests
build: ## Compile contracts
	forge build

sizes: ## Compile and report deployed-contract sizes
	forge build src $(DEPLOYMENT_ANCHORS) --sizes

# forge test omits script-only dependencies loaded through vm.deployCode.
build-deps:
	forge build $(DEPLOYMENT_ANCHORS)

test test-local test-fork test-deployment test-simulation test-mutation coverage snapshot snapshot-diff \
acceptance-run acceptance-run-multi: build-deps

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
	DEPLOYMENT_RUN= PREPARE_MARKETS=false forge coverage --report summary

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

test-plan: ## Relink TEST_PLAN.md to current tests and contract members
	python3 tools/test_plan_links.py

test-plan-check: ## Check TEST_PLAN.md links and test references
	python3 tools/test_plan_links.py --check

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
# resulting state. RUN selects script/deployment/<run>/artifacts/Deployment.sol.
test-pending: ## Apply pending action and run fork suites: CONFIG RUN RPC_URL
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	$(MAKE) apply-pending CONFIG="$(CONFIG)" RPC_URL="$(RPC_URL)" PIN_BLOCK="$(PIN_BLOCK)"
	$(MAKE) test-fork RPC_URL=http://127.0.0.1:8545 RUN="$(RUN)" PREPARE=false FORK_BLOCK=
