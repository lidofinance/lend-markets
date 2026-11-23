# Shortcuts wrap the foundry commands documented in README/AGENTS.md.
# CI calls a subset of these so local and CI behavior stay in sync.
.DEFAULT_GOAL := help

# Make normally lets an included file replace exported environment variables. Preserve the public inputs so
# precedence is consistently: command line > exported environment > .env > defaults.
DOTENV_OVERRIDE_VARS := SCRIPT DEPLOYER_SENDER DEPLOYER_ACCOUNT RUN MARKET RPC_URL HOODI_RPC_URL FORK_BLOCK \
	HOODI_FORK_BLOCK TEST_SEED FOUNDRY_FUZZ_SEED

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

DEPLOYMENT_ANCHORS := script/Bundler3Anchor.sol script/CircuitBreakerAnchor.sol

.PHONY: help build build-deps sizes deploy test test-local test-fork test-deployment test-simulation test-mutation \
	fmt fmt-check lint coverage snapshot snapshot-diff slither solhint doc test-plan test-plan-check audit-checksums ci clean \
	activation-safe-tx

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
	@echo '  test                 every suite on the default fork target (mainnet weth-wsteth); RPC_URL required'
	@echo '  test-local           unit, scenario, invariant and 30-day simulations; no RPC'
	@echo '  test-fork-<network>-<market>  one market'"'"'s fork suites; its RPC_URL or HOODI_RPC_URL'
	@echo '  test-fork            every market; run as make -k test-fork to go on past a failing market'
	@echo '  test-fork RUN=<run> RPC_URL=<rpc>               the run'"'"'s recorded markets at the latest block, created'
	@echo '  test-fork RUN=<run> PREPARE=false RPC_URL=<rpc>  the recorded markets as they are; inert ones skip'
	@echo '  test-deployment      Solidity deployment scenarios; RPC_URL, optional FORK_BLOCK'
	@echo '  test-simulation      365-day solvency simulations'
	@echo '  test-mutation        local mutation testing of src/; requires forge >= 1.8.0'
	@echo '  activation-safe-tx   MARKET=<network>/markets/<DeployScript>: the Safe transaction of its activation motion'
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

test test-local test-fork test-deployment test-simulation test-mutation coverage snapshot snapshot-diff: build-deps

test: ## Local + fresh-fork suites; RPC_URL required
	forge test

test-local: ## Local suites; no RPC
	forge test --no-match-path 'test/{fork,deployment}/**'

# One market's fork suites, in its own forge run; a network without its RPC fails. With RUN=<network>
# on the command line, the fork suites on the network's recorded market over RPC_URL at its latest block, created when
# inert unless PREPARE=false.
fork_test = FORK_DEPLOY_SCRIPT=script/deployment/$(1).s.sol forge test --match-path 'test/fork/**' -vv
ifeq ($(origin RUN),command line)
fork_test = FORK_DEPLOY_SCRIPT=script/deployment/$(1).s.sol FORK_RUN=$(RUN) FORK_RUN_PREPARE=$(or $(PREPARE),true) \
	forge test --match-path 'test/fork/**' -vv
endif
unexport fork_test

test-fork-mainnet-weth-wsteth: ; $(call fork_test,mainnet/markets/DeployWethWstethMainnet)
test-fork-mainnet-usdc-usdy: ; $(call fork_test,mainnet/markets/DeployUsdcUsdyMainnet)
test-fork-mainnet-usdc-dejtrsy: ; $(call fork_test,mainnet/markets/DeployUsdcDejtrsyMainnet)
test-fork-mainnet-usdc-jtrsy: ; $(call fork_test,mainnet/markets/DeployUsdcJtrsyMainnet)
test-fork-mainnet-usdc-dejaaa: ; $(call fork_test,mainnet/markets/DeployUsdcDejaaaMainnet)
test-fork-mainnet-usdc-jaaa: ; $(call fork_test,mainnet/markets/DeployUsdcJaaaMainnet)
test-fork-hoodi-weth-wsteth: ; $(call fork_test,hoodi/markets/DeployWethWstethHoodi)
test-fork-hoodi-usdc-usdy: ; $(call fork_test,hoodi/markets/DeployUsdcUsdyHoodi)
test-fork-hoodi-usdt-usdy: ; $(call fork_test,hoodi/markets/DeployUsdtUsdyHoodi)
test-fork-hoodi-usdc-usdy-nav: ; $(call fork_test,hoodi/markets/DeployUsdcUsdyNavHoodi)
test-fork-hoodi-usdc-jtrsy: ; $(call fork_test,hoodi/markets/DeployUsdcJtrsyHoodi)
test-fork-hoodi-usdc-dejtrsy: ; $(call fork_test,hoodi/markets/DeployUsdcDejtrsyHoodi)
test-fork-hoodi-usdc-jaaa: ; $(call fork_test,hoodi/markets/DeployUsdcJaaaHoodi)
test-fork-hoodi-usdc-dejaaa: ; $(call fork_test,hoodi/markets/DeployUsdcDejaaaHoodi)

FORK_TARGETS := test-fork-mainnet-weth-wsteth test-fork-mainnet-usdc-usdy test-fork-mainnet-usdc-dejtrsy \
	test-fork-mainnet-usdc-jtrsy test-fork-mainnet-usdc-dejaaa test-fork-mainnet-usdc-jaaa \
	test-fork-hoodi-weth-wsteth test-fork-hoodi-usdc-usdy test-fork-hoodi-usdt-usdy test-fork-hoodi-usdc-usdy-nav \
	test-fork-hoodi-usdc-jtrsy test-fork-hoodi-usdc-dejtrsy test-fork-hoodi-usdc-jaaa test-fork-hoodi-usdc-dejaaa
unexport FORK_TARGETS
.PHONY: $(FORK_TARGETS)
$(FORK_TARGETS): build-deps

test-fork: $(FORK_TARGETS) ## Every market; run with make -k

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
	forge coverage --report summary

# -vv exposes TEST_SEED and FORK_BLOCK for replay; pin FOUNDRY_FUZZ_SEED for invariant counters too.
snapshot: ## Gas snapshot including fresh-fork suites; RPC_URL required
snapshot-diff: ## Compare snapshot; use the same TEST_SEED
snapshot-diff: SNAP_FLAGS := --diff
snapshot snapshot-diff:
	forge snapshot $(SNAP_FLAGS) -vv

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

##@ Activation
# Not echoed: the command line holds the RPC URL.
activation-safe-tx: ## Print the Safe transaction of a market's activation motion: MARKET=<network>/markets/<DeployScript>
	@forge script script/deployment/$(MARKET).s.sol --sig "printActivationSafeTransaction()" \
		--rpc-url "$(if $(filter hoodi/%,$(MARKET)),$(HOODI_RPC_URL),$(RPC_URL))"
