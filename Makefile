# Shortcuts wrap the foundry commands documented in README/AGENTS.md.
# CI calls a subset of these so local and CI behavior stay in sync.

# Make normally lets an included file replace exported environment variables. Preserve the public inputs so
# precedence is consistently: command line > exported environment > .env > defaults.
DOTENV_OVERRIDE_VARS := CONFIG FORK_CONFIG RUN MARKET MARKET_A MARKET_B ORACLE GUARDIAN_GROUP PIN_BLOCK \
	VAULT ADAPTER BUNDLER RPC_URL DEPLOYER_ACCOUNT DEPLOYER_SENDER ETHERSCAN_API_KEY VERIFY RESUME CHAIN_ID EXECUTOR ARTIFACTS_DIR \
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

FMT_PATHS := src/LidoLendERC4626.sol src/GuardianSignals.sol src/controllers src/interfaces src/oracle src/libs src/periphery src/utils script test
FORK_PATH := test/fork/**

# Deployment workflow. `RUN` is the sole artifact identity: every deploy target writes below
# `deployed/$(RUN)/` by passing it as ARTIFACTS_DIR. RPC credentials stay in `.env`; the command line carries
# only the non-secret deployment choices.
CONFIG ?= mainnet
FORK_CONFIG ?= fork-$(CONFIG)
RUN ?=
MARKET ?= weth-wsteth
ORACLE ?= weth-wsteth
GUARDIAN_GROUP ?= $(MARKET)
PIN_BLOCK ?=
VAULT ?= weth-wsteth
ADAPTER ?= $(VAULT)
BUNDLER ?= mainnet
RPC_URL ?=
# Encrypted Foundry keystore name (`cast wallet import --interactive <name>`); forge prompts for its password.
# The only way to sign a broadcast: a raw key is never accepted, so it can never reach a printable command
# line, a process listing or shell history.
DEPLOYER_ACCOUNT ?=
# Sender of every broadcast: the deployer address. With DEPLOYER_ACCOUNT it is the keystore's address (forge
# derives no sender from a keystore); without it, an account the node has unlocked (anvil --auto-impersonate).
DEPLOYER_SENDER ?=
# Testnet branch: contracts stay unverified on the explorer.
VERIFY ?= false
RESUME ?= false
CHAIN_ID ?= $(shell if [ -n "$(RUN)" ] && [ -f "deployed/$(RUN)/protocol.toml" ]; then \
	awk -F= '/^[[:space:]]*chain_id[[:space:]]*=/{gsub(/[[:space:]]/, "", $$2); print $$2; exit}' "deployed/$(RUN)/protocol.toml"; \
	else \
	awk -F= '/^[[:space:]]*chain_id[[:space:]]*=/{gsub(/[[:space:]]/, "", $$2); print $$2; exit}' "script/config/$(CONFIG).toml"; \
	fi)

# The activation motion is broadcast as the run's own EVMScriptExecutor (impersonated on a fork), so it is
# read from the run rather than passed in.
EXECUTOR ?= $(shell if [ -n "$(RUN)" ] && [ -f "deployed/$(RUN)/protocol.toml" ]; then \
	awk -F= '/^[[:space:]]*evm_script_executor[[:space:]]*=/{gsub(/[[:space:]"]/, "", $$2); print $$2; exit}' "deployed/$(RUN)/protocol.toml"; \
	fi)

DEPLOY_ENV = ARTIFACTS_DIR="$(RUN)"
VERIFY_FLAGS = $(if $(filter true,$(VERIFY)),--verify,)
RESUME_FLAGS = $(if $(filter true,$(RESUME)),--resume,)
SIGNER_FLAGS = --sender "$(DEPLOYER_SENDER)" $(if $(DEPLOYER_ACCOUNT),--account "$(DEPLOYER_ACCOUNT)",--unlocked)
DEPLOY_FLAGS = --rpc-url "$(RPC_URL)" $(SIGNER_FLAGS) --broadcast $(VERIFY_FLAGS) $(RESUME_FLAGS)

define archive_broadcast
	@test -n "$(CHAIN_ID)" || { echo "ERROR: could not read chain_id from script/config/$(CONFIG).toml"; exit 1; }
	@test -f "broadcast/$(1)/$(CHAIN_ID)/run-latest.json" || { echo "ERROR: Foundry broadcast record missing for $(1)"; exit 1; }
	@test ! -e "deployed/$(RUN)/transactions/$(2).json" || { echo "ERROR: transaction record already exists: $(2)"; exit 1; }
	@mkdir -p "deployed/$(RUN)/transactions"
	@cp "broadcast/$(1)/$(CHAIN_ID)/run-latest.json" "deployed/$(RUN)/transactions/$(2).json"
endef

.PHONY: help build sizes test test-local test-fork test-simulation test-mutation deploy-oracle deploy-oracle-usdy deploy-circuit-breaker deploy-guardian deploy-vault-v2 verify-vault-v2 deploy-bundler verify-bundler deploy-exit-books deploy-protocol deploy-market deploy-run deploy-all activate-markets fork-activate deploy-wizard state-mate-config acceptance-run acceptance-run-multi fork-run fmt fmt-check lint coverage snapshot snapshot-diff slither solhint doc ci clean provision-fork provision-stop apply-pending pending-stop test-pending test-fork-live test-fork-provision

help:
	@echo "Targets:"
	@echo "  build         forge build"
	@echo "  sizes         forge build --sizes"
	@echo "  test          all tests, local + fork in one run; fork suites require RPC_URL + ARTIFACTS_DIR"
	@echo "  test-local    forge test on the local suites only (excludes test/fork/; no RPC)"
	@echo "  test-fork     forge test on test/fork/ only; the suites revert without the fork setup"
	@echo "  test-simulation  the year-long solvency simulations (test/simulation/); the 30-day variants run in test-local"
	@echo "  test-mutation forge mutation testing of src/ over the 30-day simulations (slow; needs forge >= 1.8.0,"
	@echo "                which is NOT the pinned .foundryref toolchain, so install it separately)"
	@echo "  deploy-oracle CONFIG=<config> RUN=<run> ORACLE=<name>"
	@echo "  deploy-circuit-breaker CONFIG=<config> RUN=<run>"
	@echo "  deploy-protocol CONFIG=<config> RUN=<run>  (backbone + exit books; markets are separate)"
	@echo "  deploy-guardian CONFIG=<config> RUN=<run> GUARDIAN_GROUP=<group>  (before its markets)"
	@echo "  deploy-vault-v2 CONFIG=<config> RUN=<existing-run> VAULT=<name> ADAPTER=<name>"
	@echo "  verify-vault-v2 RUN=<run> VAULT=<name> ADAPTER=<name>  (deploy-vault-v2 runs this itself)"
	@echo "  deploy-bundler CONFIG=<config> RUN=<existing-run> BUNDLER=<name>  (Bundler3 + adapters over the run's core)"
	@echo "  verify-bundler RUN=<run> BUNDLER=<name>  (deploy-bundler runs this itself)"
	@echo "  deploy-exit-books CONFIG=<config> RUN=<existing-run>"
	@echo "  deploy-market CONFIG=<config> RUN=<run> MARKET=<name>"
	@echo "  deploy-run CONFIG=<config> RUN=<run> ORACLE=<name> MARKET=<name>"
	@echo "  deploy-all CONFIG=<config> RUN=<run> [RPC_URL=<rpc>]  (every resource the config declares)"
	@echo "             (current single-CircuitBreaker, single-oracle, single-market workflow)"
	@echo "                 deploy targets verify by default; set VERIFY=false for local networks"
	@echo "                 retry an interrupted target immediately with RESUME=true"
	@echo "  deploy-wizard interactive wrapper around the deploy targets"
	@echo "  activate-markets RUN=<run>  (replays the activation motion; fork/devnet only)"
	@echo "  fork-activate RUN=<run> RPC_URL=<local>  (impersonate the executor, then activate)"
	@echo "  acceptance-run RUN=<run> MARKET=<name>"
	@echo "  acceptance-run-multi RUN=<run> MARKET_A=<name> MARKET_B=<name>"
	@echo "  fork-run RUN=<run>  (read-only fork tests against this deployment)"
	@echo "               deploy targets write immutable artifacts and archive broadcast JSON under deployed/<run>/"
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
	@echo "  provision-fork CONFIG=<network> [FORK_CONFIG=<config>] [PIN_BLOCK=<n>]"
	@echo "                  deploy + activate using fork-<network> config by default"
	@echo "                  RPC_URL is the archive node when no compatible anvil already runs"
	@echo "                  PIN_BLOCK pins the upstream block, making the run reproducible"
	@echo "  test-fork-live  run the fork suites against an already-provisioned local anvil"
	@echo "  provision-stop  stop the anvil provision-fork started"
	@echo "  test-fork-provision  one-shot: provision -> test; stops only an anvil started by this invocation"

build:
	forge build

sizes:
	forge build --sizes

# All tests, local + fork, in one run. The fork suites revert without a working fork setup — RPC_URL and
# ARTIFACTS_DIR set (see .env.example), that deploy run on disk, and the RPC answering. Use test-local /
# test-fork for one side on its own.
test:
	forge test

# Everything under test/ except test/fork/ — no RPC involved.
test-local:
	forge test --no-match-path '$(FORK_PATH)'

# Fork suites only; they revert without a working fork setup.
test-fork:
	forge test --match-path '$(FORK_PATH)'

# The 365-day solvency simulations; the 30-day runs are part of test-local. The gas limit is set in foundry.toml.
test-simulation:
	RUN_SOLVENCY_SIMULATION=true forge test --match-path 'test/simulation/**' -vv

# Outside the pinned toolchain: `--mutate` landed in forge 1.8.0 and `.foundryref` pins 1.7.1, so neither CI nor a
# standard local setup can run this. It needs a separately installed forge, and a run under 1.8.x is not comparable
# with a pinned run: isolate mode makes every call its own transaction, which moves gas and the simulation's
# transaction boundary (`perCallTransactions`). Local only, never in CI. The score counts only the mutants forge
# evaluates; it skips many.
test-mutation:
	@forge test --help | grep -q -- '--mutate' || { echo "test-mutation: the local forge ($$(forge --version | head -1)) has no mutation testing; it needs forge >= 1.8.0, which is not the pinned .foundryref toolchain (install it separately, e.g. foundryup -i v1.8.3)"; exit 1; }
	TEST_SEED=1 forge test --mutate src --match-path 'test/simulation/**' --match-test shortRun --mutation-timeout 900

# The helper is deliberately repeated by each target: invoking `make deploy-protocol` directly is as safe as
# calling it through `deploy-run`.
define require_deploy_context
	@test -n "$(RUN)" || { echo "ERROR: set RUN (for example RUN=mainnet-weth-wsteth)"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	@test -n "$(DEPLOYER_SENDER)" || { echo "ERROR: set DEPLOYER_SENDER (the deployer address) and DEPLOYER_ACCOUNT (its keystore), or DEPLOYER_SENDER alone for an unlocked local node"; exit 1; }
	@test "$(VERIFY)" = "true" || test "$(VERIFY)" = "false" || { echo "ERROR: VERIFY must be true or false"; exit 1; }
	@test "$(RESUME)" = "true" || test "$(RESUME)" = "false" || { echo "ERROR: RESUME must be true or false"; exit 1; }
	@test "$(VERIFY)" = "false" || test -n "$(ETHERSCAN_API_KEY)" || { echo "ERROR: set ETHERSCAN_API_KEY or use VERIFY=false"; exit 1; }
endef

deploy-oracle:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployWstEthOracle.s.sol --sig 'run(string,string)' "$(CONFIG)" "$(ORACLE)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployWstEthOracle.s.sol,oracle-$(ORACLE))

deploy-oracle-usdy:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployUsdyOracle.s.sol --sig 'run(string,string)' "$(CONFIG)" "$(ORACLE)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployUsdyOracle.s.sol,oracle-$(ORACLE))

deploy-circuit-breaker:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployCircuitBreaker.s.sol --sig 'run(string)' "$(CONFIG)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployCircuitBreaker.s.sol,circuit-breaker)

deploy-guardian:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployGuardianSignals.s.sol --sig 'run(string,string)' "$(CONFIG)" "$(GUARDIAN_GROUP)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployGuardianSignals.s.sol,guardian-$(GUARDIAN_GROUP))

# The vault + its Morpho adapter in one broadcast: the adapter's parent vault is a constructor immutable.
# Needs an existing run — the adapter's other immutables are that run's core and IRM router.
deploy-vault-v2:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployVaultV2.s.sol --sig 'run(string,string,string)' "$(CONFIG)" "$(VAULT)" "$(ADAPTER)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployVaultV2.s.sol,vault-v2-$(VAULT))
	@test "$(VERIFY)" = "false" || $(MAKE) verify-vault-v2 RUN="$(RUN)" VAULT="$(VAULT)" ADAPTER="$(ADAPTER)"

# The vault-v2 pair is created with vm.deployCode, which records the creations without a contract name, so
# `forge script --verify` skips them. Verify them explicitly from the addresses and constructor arguments the
# artifacts recorded.
verify-vault-v2:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(VAULT)" || { echo "ERROR: set VAULT"; exit 1; }
	@test -n "$(ADAPTER)" || { echo "ERROR: set ADAPTER"; exit 1; }
	@test -n "$(ETHERSCAN_API_KEY)" || { echo "ERROR: set ETHERSCAN_API_KEY"; exit 1; }
	@ARTIFACTS_DIR="$(RUN)" forge script script/DeployVaultV2.s.sol \
		--sig 'validateArtifacts(string,string)' "$(VAULT)" "$(ADAPTER)"
	@set -e; \
	V="deployed/$(RUN)/vaults/$(VAULT).toml"; A="deployed/$(RUN)/adapters/$(ADAPTER).toml"; \
	test -f "$$V" || { echo "ERROR: no vault artifact at $$V"; exit 1; }; \
	test -f "$$A" || { echo "ERROR: no adapter artifact at $$A"; exit 1; }; \
	key() { sed -n "s/^[[:space:]]*$$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$$1" | head -1; }; \
	forge verify-contract "$$(key $$V address)" lib/vault-v2/src/VaultV2.sol:VaultV2 \
		--chain "$(CHAIN_ID)" --watch \
		--constructor-args "$$(cast abi-encode 'constructor(address,address)' \
			"$$(key $$V owner)" "$$(key $$V asset)")"; \
	forge verify-contract "$$(key $$A address)" \
		lib/vault-v2/src/adapters/MorphoMarketV1AdapterV2.sol:MorphoMarketV1AdapterV2 \
		--chain "$(CHAIN_ID)" --watch \
		--constructor-args "$$(cast abi-encode 'constructor(address,address,address)' \
			"$$(key $$A vault)" "$$(key $$A morpho)" "$$(key $$A adaptive_curve_irm)")"

# This run's own bundler stack over an existing run: a fresh Bundler3 dispatcher, the general adapter bound to it
# and to the run's core, and the vault adapter bound to it.
deploy-bundler:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployBundler.s.sol --sig 'run(string,string)' "$(CONFIG)" "$(BUNDLER)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployBundler.s.sol,bundler-$(BUNDLER))
	@test "$(VERIFY)" = "false" || $(MAKE) verify-bundler RUN="$(RUN)" BUNDLER="$(BUNDLER)"

# Bundler3 and the general adapter are created with vm.deployCode (nameless creations `forge script --verify`
# skips), so they are verified explicitly from the addresses and constructor arguments the artifact recorded; the
# vault adapter is created with `new` and verified by the script run.
verify-bundler:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(BUNDLER)" || { echo "ERROR: set BUNDLER"; exit 1; }
	@test -n "$(ETHERSCAN_API_KEY)" || { echo "ERROR: set ETHERSCAN_API_KEY"; exit 1; }
	@ARTIFACTS_DIR="$(RUN)" forge script script/DeployBundler.s.sol --sig 'validateArtifacts(string)' "$(BUNDLER)"
	@set -e; \
	B="deployed/$(RUN)/bundler.toml"; \
	test -f "$$B" || { echo "ERROR: no bundler artifact at $$B"; exit 1; }; \
	key() { sed -n "s/^[[:space:]]*$$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$$1" | head -1; }; \
	forge verify-contract "$$(key $$B bundler3)" lib/bundler3/src/Bundler3.sol:Bundler3 \
		--chain "$(CHAIN_ID)" --watch; \
	forge verify-contract "$$(key $$B general_adapter)" \
		src/adapters/EthereumGeneralAdapter1.sol:EthereumGeneralAdapter1 \
		--chain "$(CHAIN_ID)" --watch \
		--constructor-args "$$(cast abi-encode 'constructor(address,address,address,address)' \
			"$$(key $$B bundler3)" "$$(key $$B morpho)" "$$(key $$B weth)" "$$(key $$B wsteth)")"

deploy-exit-books:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployExitBooks.s.sol --sig 'run(string)' "$(CONFIG)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployExitBooks.s.sol,exit-books)

deploy-protocol:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/DeployProtocol.s.sol --sig 'run(string)' "$(CONFIG)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,DeployProtocol.s.sol,protocol)

deploy-market:
	$(require_deploy_context)
	@$(DEPLOY_ENV) forge script script/AddMarket.s.sol --sig 'run(string,string)' "$(CONFIG)" "$(MARKET)" $(DEPLOY_FLAGS)
	$(call archive_broadcast,AddMarket.s.sol,market-$(MARKET))

# The current mainnet profile has one WstETH oracle and one market. Keep the composition explicit until the
# config itself contains a typed deploy plan; do not guess an oracle implementation from a market name in Make.
deploy-run:
	$(MAKE) deploy-circuit-breaker CONFIG="$(CONFIG)" RUN="$(RUN)"
	$(MAKE) deploy-oracle CONFIG="$(CONFIG)" RUN="$(RUN)" ORACLE="$(ORACLE)"
	$(MAKE) deploy-protocol CONFIG="$(CONFIG)" RUN="$(RUN)"
	$(MAKE) deploy-guardian CONFIG="$(CONFIG)" RUN="$(RUN)" GUARDIAN_GROUP="$(GUARDIAN_GROUP)"
	$(MAKE) deploy-market CONFIG="$(CONFIG)" RUN="$(RUN)" MARKET="$(MARKET)"

# Every resource the deploy config declares under [provision], in the order the scripts require.
toml_list = $(shell awk -v k='$(1)' 'f&&/^\[/{f=0} /^\[provision\]/{f=1;next} f&&$$1==k{sub(/^[^=]*=[[:space:]]*/,""); gsub(/[][",]/," "); print}' script/config/$(CONFIG).toml)
ORACLES ?= $(call toml_list,oracles)
GUARDIAN_GROUPS ?= $(call toml_list,guardians)
MARKETS ?= $(call toml_list,markets)

# Every provisioning step of CONFIG, resumable: a step whose artifact records a contract already on chain is
# skipped, and an artifact without one stops the run (script/deploy-step.sh). Each step prompts for the keystore
# password; a mistyped one sends and writes nothing, so the run is simply repeated. The keystore is checked to
# unlock DEPLOYER_SENDER first: forge only notices a mismatch after the simulation has written the artifact.
STEP = script/deploy-step.sh
STEP_VARS = CONFIG="$(CONFIG)" RUN="$(RUN)"

deploy-all:
	$(require_deploy_context)
	@if [ -n "$(DEPLOYER_ACCOUNT)" ]; then \
	  addr=$$(cast wallet address --account "$(DEPLOYER_ACCOUNT)") || exit 1; \
	  [ "$$addr" = "$$(cast to-check-sum-address "$(DEPLOYER_SENDER)")" ] \
	    || { echo "ERROR: keystore $(DEPLOYER_ACCOUNT) unlocks $$addr, not DEPLOYER_SENDER $(DEPLOYER_SENDER)"; exit 1; }; \
	fi
	@$(STEP) "deployed/$(RUN)/circuit-breakers/lido-lend.toml" address "$(RPC_URL)" deploy-circuit-breaker $(STEP_VARS)
	@for o in $(ORACLES); do \
	  kind=$$(sed -n 's/^[[:space:]]*kind[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' script/config/oracles/$$o.toml); \
	  case "$$kind" in \
	    usdy) t=deploy-oracle-usdy ;; \
	    wsteth) t=deploy-oracle ;; \
	    *) echo "ERROR: unknown oracle kind '$$kind' in $$o.toml"; exit 1 ;; \
	  esac; \
	  $(STEP) "deployed/$(RUN)/oracles/$$o.toml" address "$(RPC_URL)" $$t $(STEP_VARS) ORACLE=$$o || exit 1; \
	done
	@$(STEP) "deployed/$(RUN)/protocol.toml" core "$(RPC_URL)" deploy-protocol $(STEP_VARS)
	@for g in $(GUARDIAN_GROUPS); do \
	  $(STEP) "deployed/$(RUN)/guardians/$$g.toml" address "$(RPC_URL)" deploy-guardian $(STEP_VARS) GUARDIAN_GROUP=$$g || exit 1; \
	done
	@for m in $(MARKETS); do \
	  $(STEP) "deployed/$(RUN)/markets/$$m.toml" controller "$(RPC_URL)" deploy-market $(STEP_VARS) MARKET=$$m || exit 1; \
	done

# Replays the LidoLendActivateMarket motion for every market in the run, broadcasting as the impersonated
# EVMScriptExecutor. Fork and devnet only: on a real network activation is an EasyTrack motion, not a script.
# Fork only: fund and impersonate the EVMScriptExecutor on the local node, then replay the activation motion
# for every market in the run. Markets must be activated before the fork suites can bind them.
fork-activate:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL (the local node)"; exit 1; }
	@test -n "$(EXECUTOR)" || { echo "ERROR: could not read evm_script_executor from deployed/$(RUN)/protocol.toml"; exit 1; }
	@cast rpc anvil_setBalance "$(EXECUTOR)" 0x8AC7230489E80000 --rpc-url "$(RPC_URL)" >/dev/null \
	  || { echo "ERROR: $(RPC_URL) is not an Anvil node (anvil_setBalance failed)"; exit 1; }
	@cast rpc anvil_impersonateAccount "$(EXECUTOR)" --rpc-url "$(RPC_URL)" >/dev/null \
	  || { echo "ERROR: cannot impersonate $(EXECUTOR)"; exit 1; }
	$(MAKE) activate-markets RUN="$(RUN)" RPC_URL="$(RPC_URL)"

activate-markets:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	@test -n "$(EXECUTOR)" || { echo "ERROR: could not read evm_script_executor from deployed/$(RUN)/protocol.toml"; exit 1; }
	@$(DEPLOY_ENV) forge script script/ActivateMarkets.s.sol --sig 'run()' \
		--rpc-url "$(RPC_URL)" --unlocked --sender "$(EXECUTOR)" --broadcast

# Post-activation state-mate configs for RUN: addresses from its artifacts, expectations from script/config/,
# proxy implementations from the node at RPC_URL. Written next to script/config/state-mate/generate.py.
state-mate-config:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL (the node the run lives on)"; exit 1; }
	RUN="$(RUN)" HOODI_RPC_URL="$(RPC_URL)" python3 script/config/state-mate/generate.py

acceptance-run:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(MARKET)" || { echo "ERROR: set MARKET"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	ACCEPTANCE_RPC_URL="$(RPC_URL)" ACCEPTANCE_REGISTRY="deployed/$(RUN)/protocol.toml" MARKET="$(MARKET)" forge test --match-path 'test/acceptance/*' --no-match-contract MultiMarketActivationSimulation -vvv

acceptance-run-multi:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(MARKET_A)" || { echo "ERROR: set MARKET_A"; exit 1; }
	@test -n "$(MARKET_B)" || { echo "ERROR: set MARKET_B"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	ACCEPTANCE_RPC_URL="$(RPC_URL)" ACCEPTANCE_REGISTRY="deployed/$(RUN)/protocol.toml" MARKET="$(MARKET_A)" MARKET_A="$(MARKET_A)" MARKET_B="$(MARKET_B)" forge test --match-contract MultiMarketActivationSimulation -vvv

# Run the read-only fork suites against this deploy run: they read deployed/$(RUN)/ directly, so there is
# nothing to compose or prepare first.
fork-run:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL in .env"; exit 1; }
	ARTIFACTS_DIR="$(RUN)" forge test --match-path '$(FORK_PATH)'

# Convenience only. The normal targets above remain scriptable and CI-friendly.
deploy-wizard:
	@printf 'Config [mainnet]: '; read config; config=$${config:-mainnet}; \
	printf 'Run directory (required): '; read run; test -n "$$run" || { echo 'ERROR: run directory is required'; exit 1; }; \
	printf 'Step (circuit-breaker, oracle, oracle-usdy, guardian, vault-v2, bundler, exit-books, protocol, market, full) [full]: '; read step; step=$${step:-full}; \
	printf 'Resource name (shared by oracle/guardian/market for full; the bundler config for bundler; ignored for circuit-breaker/protocol/exit-books): '; read name; \
	name=$${name:-weth-wsteth}; \
	case "$$step" in \
		circuit-breaker) exec $(MAKE) deploy-circuit-breaker CONFIG="$$config" RUN="$$run" ;; \
		oracle) exec $(MAKE) deploy-oracle CONFIG="$$config" RUN="$$run" ORACLE="$$name" ;; \
		oracle-usdy) exec $(MAKE) deploy-oracle-usdy CONFIG="$$config" RUN="$$run" ORACLE="$$name" ;; \
		guardian) exec $(MAKE) deploy-guardian CONFIG="$$config" RUN="$$run" GUARDIAN_GROUP="$$name" ;; \
		vault-v2) exec $(MAKE) deploy-vault-v2 CONFIG="$$config" RUN="$$run" VAULT="$$name" ADAPTER="$$name" ;; \
		bundler) exec $(MAKE) deploy-bundler CONFIG="$$config" RUN="$$run" BUNDLER="$$name" ;; \
		exit-books) exec $(MAKE) deploy-exit-books CONFIG="$$config" RUN="$$run" ;; \
		protocol) exec $(MAKE) deploy-protocol CONFIG="$$config" RUN="$$run" ;; \
		market) exec $(MAKE) deploy-market CONFIG="$$config" RUN="$$run" MARKET="$$name" ;; \
		full) exec $(MAKE) deploy-run CONFIG="$$config" RUN="$$run" ORACLE="$$name" MARKET="$$name" GUARDIAN_GROUP="$$name" ;; \
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

# Deploy + activate the fork markets on a local anvil fork of CONFIG's network, leaving `deployed/fork/` for the
# fork suites to bind to. Every step is an ordinary deploy target; only the final activation is a script rather
# than a governance motion. FORK_CONFIG defaults to fork-$(CONFIG), keeping test-only role holders out of the
# production config. RPC_URL is the upstream archive node when the driver starts anvil; deploy steps target the
# local node in either mode.
provision-fork:
	@PROVISION_RESULT_FILE="$(PROVISION_RESULT_FILE)" PROVISION_REQUEST_TOKEN="$(PROVISION_REQUEST_TOKEN)" \
		bash script/provision-fork.sh "$(RPC_URL)" "$(FORK_CONFIG)" "$(PIN_BLOCK)"

provision-stop:
	bash script/provision-fork.sh stop

# Run the fork suites against a provisioned local anvil without touching it — the iterative path while editing
# tests. Fails with what to do when nothing is provisioned.
test-fork-live:
	bash script/provision-fork.sh check
	$(MAKE) test-fork RPC_URL=http://127.0.0.1:8545 ARTIFACTS_DIR=fork FORK_BLOCK=

# Pending multisig action: fork the live network, apply the transaction(s) from
# script/config/pending/<CONFIG>.toml, and leave the fork on :8545 for test-fork / state-mate.
apply-pending:
	@test -n "$(RPC_URL)" || { echo "ERROR: set RPC_URL to the live network's RPC"; exit 1; }
	bash script/pending-action.sh apply "$(CONFIG)" "$(PIN_BLOCK)"

pending-stop:
	bash script/pending-action.sh stop

# Full pre-signing validation: apply the pending action, then run the fork suites against the
# resulting state. RUN names the live run's artifacts under deployed/<run>/.
test-pending:
	@test -n "$(RUN)" || { echo "ERROR: set RUN"; exit 1; }
	$(MAKE) apply-pending CONFIG="$(CONFIG)" RPC_URL="$(RPC_URL)" PIN_BLOCK="$(PIN_BLOCK)"
	$(MAKE) test-fork RPC_URL=http://127.0.0.1:8545 ARTIFACTS_DIR="$(RUN)" FORK_BLOCK=

# One-shot local flow. A private request/result handshake says whether this invocation started or reused Anvil;
# cleanup stops only the exact started identity, including when a signal lands as recursive make returns.
test-fork-provision:
	@set -e; \
	umask 077; \
	tmp_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/lido-lend-provision.XXXXXX"); \
	result_file="$$tmp_dir/result"; request_token="request-$${tmp_dir##*/}-$$$$"; \
	started_pid=; started_at=; started_token=; result_mode=; \
	load_result() { \
		test -f "$$result_file" || return 1; \
		test "$$(sed -n '1p' "$$result_file")" = "$$request_token" || return 2; \
		result_mode=$$(sed -n '2p' "$$result_file"); \
		case "$$result_mode" in \
			reused) started_pid=; started_at=; started_token= ;; \
			started) \
				started_pid=$$(sed -n '3p' "$$result_file"); \
				started_at=$$(sed -n '4p' "$$result_file"); \
				started_token=$$(sed -n '5p' "$$result_file"); \
				case "$$started_pid" in ''|*[!0-9]*) return 3 ;; esac; \
				test -n "$$started_at" && test -n "$$started_token" || return 3 ;; \
			*) return 3 ;; \
		esac; \
	}; \
	cleanup() { \
		status=$$?; trap - EXIT HUP INT TERM; set +e; \
		load_result; result_status=$$?; \
		if test "$$result_status" -eq 0 && test "$$result_mode" = started; then \
			bash script/provision-fork.sh stop-if-owned "$$started_pid" "$$started_at" "$$started_token"; stop_status=$$?; \
			test "$$status" -ne 0 || status=$$stop_status; \
		fi; \
		test "$$status" -ne 0 || test "$$result_status" -eq 0 || status=1; \
		rm -rf "$$tmp_dir"; \
		exit "$$status"; \
	}; \
	trap cleanup EXIT; \
	trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM; \
	$(MAKE) provision-fork PROVISION_RESULT_FILE="$$result_file" PROVISION_REQUEST_TOKEN="$$request_token"; \
	load_result || { echo 'ERROR: provision did not publish a valid result for this invocation' >&2; exit 1; }; \
	$(MAKE) test-fork RPC_URL=http://127.0.0.1:8545 ARTIFACTS_DIR=fork FORK_BLOCK=
