# Shortcuts wrap the foundry commands documented in README/AGENTS.md.
# CI calls a subset of these so local and CI behavior stay in sync.

-include .env
export

FMT_PATHS := src/LidoBlueERC4626.sol src/SuspectsRegistry.sol src/controllers src/interfaces src/oracle src/libs src/utils test
FORK_PATH := test/fork/**

# Deployment workflow. `RUN` is the sole artifact identity: every deploy target writes below
# `deployed/$(RUN)/` by passing it as ARTIFACTS_DIR. RPC credentials stay in `.env`; the command line carries
# only the non-secret deployment choices.
CONFIG ?= mainnet
RUN ?=
MARKET ?= weth-wsteth
ORACLE ?= weth-wsteth
GUARDIAN_GROUP ?= $(MARKET)
NETWORK ?= $(CONFIG)
RPC_URL ?=
DEPLOYER_PRIVATE_KEY ?=
CHAIN_ID ?= $(shell awk -F= '/^[[:space:]]*chain_id[[:space:]]*=/{gsub(/[[:space:]]/, "", $$2); print $$2; exit}' script/config/$(CONFIG).toml)

DEPLOY_ENV = ARTIFACTS_DIR="$(RUN)"
DEPLOY_FLAGS = --rpc-url "$(RPC_URL)" --private-key "$(DEPLOYER_PRIVATE_KEY)" --broadcast

define archive_broadcast
	@test -n "$(CHAIN_ID)" || { echo "ERROR: could not read chain_id from script/config/$(CONFIG).toml"; exit 1; }
	@test -f "broadcast/$(1)/$(CHAIN_ID)/run-latest.json" || { echo "ERROR: Foundry broadcast record missing for $(1)"; exit 1; }
	@test ! -e "deployed/$(RUN)/transactions/$(2).json" || { echo "ERROR: transaction record already exists: $(2)"; exit 1; }
	@mkdir -p "deployed/$(RUN)/transactions"
	@cp "broadcast/$(1)/$(CHAIN_ID)/run-latest.json" "deployed/$(RUN)/transactions/$(2).json"
endef

.PHONY: help build sizes test test-local test-fork deploy-oracle deploy-oracle-usdy deploy-guardian deploy-protocol deploy-market deploy-run deploy-wizard acceptance-run fork-run fmt fmt-check lint coverage snapshot snapshot-diff slither solhint doc ci clean

help:
	@echo "Targets:"
	@echo "  build         forge build"
	@echo "  sizes         forge build --sizes"
	@echo "  test          all tests, local + fork in one run; fork suites revert without the fork setup (ETH_RPC_URL + DEPLOYMENT)"
	@echo "  test-local    forge test on the local suites only (excludes test/fork/; no RPC)"
	@echo "  test-fork     forge test on test/fork/ only; the suites revert without the fork setup"
	@echo "  deploy-oracle CONFIG=<config> RUN=<run> ORACLE=<name>"
	@echo "  deploy-protocol CONFIG=<config> RUN=<run>"
	@echo "  deploy-guardian CONFIG=<config> RUN=<run> GUARDIAN_GROUP=<group>"
	@echo "  deploy-market CONFIG=<config> RUN=<run> MARKET=<name>"
	@echo "  deploy-run CONFIG=<config> RUN=<run> ORACLE=<name>  (current WstETH workflow)"
	@echo "  deploy-wizard interactive wrapper around the deploy targets"
	@echo "  acceptance-run CONFIG=<config> RUN=<run> MARKET=<name>"
	@echo "  fork-run CONFIG=<config> RUN=<run>  (read-only fork tests against this registry)"
	@echo "               deploy targets snapshot inputs and archive broadcast JSON under deployed/<run>/"
	@echo "  fmt           forge fmt on tracked paths (local only; rewrites files)"
	@echo "  fmt-check     forge fmt --check on tracked paths (local only; CI does not fail on style)"
	@echo "  lint          forge lint"
	@echo "  coverage      forge coverage over the whole suite; fork suites revert without the fork setup"
	@echo "  snapshot      forge snapshot of the whole suite -> .gas-snapshot; fork suites revert without the fork setup"
	@echo "  snapshot-diff same run, diffed against .gas-snapshot (run both at the same TEST_SEED)"
	@echo "  slither       slither . (needs slither installed)"
	@echo "  solhint       solhint 'src/**/*.sol' (needs node + solhint installed)"
	@echo "  doc           forge build --ast + regenerate docs/specs/api/ from NatSpec"
	@echo "  ci            build + lint + test-local  (mirrors ci.yml's local job)"
	@echo "  clean         forge clean"

build:
	forge build

sizes:
	forge build --sizes

# All tests, local + fork, in one run. The fork suites revert without a working fork setup — ETH_RPC_URL and
# DEPLOYMENT set (see .env.example), the map on disk, the RPC answering — so missing configuration fails the
# run. Use test-local / test-fork for one side on its own.
test:
	forge test

# Everything under test/ except test/fork/ — no RPC involved.
test-local:
	forge test --no-match-path '$(FORK_PATH)'

# Fork suites only; they revert without a working fork setup.
test-fork:
	forge test --match-path '$(FORK_PATH)'

# The helper is deliberately repeated by each target: invoking `make deploy-protocol` directly is as safe as
# calling it through `deploy-run`.
define require_deploy_context
	@test -n "$(RUN)" || { echo "ERROR: set RUN (for example RUN=mainnet-weth-wsteth)"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	@test -n "$(DEPLOYER_PRIVATE_KEY)" || { echo "ERROR: set DEPLOYER_PRIVATE_KEY in .env"; exit 1; }
endef

deploy-oracle:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployWstEthOracle.s.sol --sig 'run(string,string)' "$(CONFIG)" "$(ORACLE)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployWstEthOracle.s.sol,oracle-$(ORACLE))

deploy-oracle-usdy:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployUsdyOracle.s.sol --sig 'run(string,string)' "$(CONFIG)" "$(ORACLE)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployUsdyOracle.s.sol,oracle-$(ORACLE))

deploy-guardian:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployGuardianSignals.s.sol --sig 'run(string,string)' "$(CONFIG)" "$(GUARDIAN_GROUP)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployGuardianSignals.s.sol,guardian-$(GUARDIAN_GROUP))

deploy-protocol:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployProtocol.s.sol --sig 'run(string)' "$(CONFIG)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployProtocol.s.sol,protocol)

deploy-market:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/AddMarket.s.sol --sig 'run(string,string)' "$(CONFIG)" "$(MARKET)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,AddMarket.s.sol,market-$(MARKET))

# The current mainnet profile has one WstETH oracle. Keep the composition explicit until the config itself
# contains a typed oracle deploy plan; do not guess an oracle implementation from a market name in Make.
deploy-run:
	$(MAKE) deploy-oracle CONFIG="$(CONFIG)" RUN="$(RUN)" ORACLE="$(ORACLE)"
	$(MAKE) deploy-protocol CONFIG="$(CONFIG)" RUN="$(RUN)"

acceptance-run:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	ACCEPTANCE_RPC_URL="$(RPC_URL)" ACCEPTANCE_REGISTRY="deployed/$(RUN)/registry.toml" MARKET="$(MARKET)" forge test --match-path 'test/acceptance/*' -vvv

fork-run:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	ETH_RPC_URL="$(RPC_URL)" FORK_REGISTRY="deployed/$(RUN)/registry.toml" NETWORK="$(NETWORK)" forge test --match-path '$(FORK_PATH)'

# Convenience only. The normal targets above remain scriptable and CI-friendly.
deploy-wizard:
	@printf 'Config [mainnet]: '; read config; config=$${config:-mainnet}; \
	printf 'Run directory (required): '; read run; test -n "$$run" || { echo 'ERROR: run directory is required'; exit 1; }; \
	printf 'Step (oracle, oracle-usdy, guardian, protocol, market, full) [full]: '; read step; step=$${step:-full}; \
	printf 'Market/oracle name [weth-wsteth]: '; read name; name=$${name:-weth-wsteth}; \
	case "$$step" in \
		oracle) exec $(MAKE) deploy-oracle CONFIG="$$config" RUN="$$run" ORACLE="$$name" ;; \
		oracle-usdy) exec $(MAKE) deploy-oracle-usdy CONFIG="$$config" RUN="$$run" ORACLE="$$name" ;; \
		guardian) exec $(MAKE) deploy-guardian CONFIG="$$config" RUN="$$run" GUARDIAN_GROUP="$$name" ;; \
		protocol) exec $(MAKE) deploy-protocol CONFIG="$$config" RUN="$$run" ;; \
		market) exec $(MAKE) deploy-market CONFIG="$$config" RUN="$$run" MARKET="$$name" ;; \
		full) exec $(MAKE) deploy-run CONFIG="$$config" RUN="$$run" ORACLE="$$name" ;; \
		*) echo 'ERROR: unknown step'; exit 1 ;; \
	esac

fmt:
	forge fmt $(FMT_PATHS)

fmt-check:
	forge fmt --check $(FMT_PATHS)

lint:
	forge lint

# Coverage of the whole suite, fork suites included — they revert without a working fork setup.
coverage:
	forge coverage --ir-minimum --report summary

# One snapshot for the whole suite, fork suites included — they revert without a working fork setup, so
# nothing is silently skipped. No entropy is minted here: foundry seeds one RNG per run, so every suite that falls back to
# `vm.randomUint()` draws the same TEST_SEED, and each fork suite logs the block it actually forked. `-vv`
# makes those logs visible (foundry hides console logs below that) — export the logged TEST_SEED / FORK_BLOCK
# to replay the run. Replay reproduces every gas number; only the invariant suites' `reverts` counters (no
# gas content) ride foundry's own fuzz RNG, which foundry does not report — set FOUNDRY_FUZZ_SEED to pin
# those too.
snapshot-diff: SNAP_FLAGS := --diff
snapshot snapshot-diff:
	forge snapshot $(SNAP_FLAGS) -vv

slither:
	slither .

solhint:
	solhint 'src/**/*.sol'

doc:
	forge build --ast
	python3 tools/gen_api_from_artifacts.py

ci: build lint test-local

clean:
	forge clean
