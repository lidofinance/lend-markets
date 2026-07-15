# Shortcuts wrap the foundry commands documented in README/AGENTS.md.
# CI calls a subset of these so local and CI behavior stay in sync.

-include .env
export

FMT_PATHS := src/LidoBlueERC4626.sol src/SuspectsRegistry.sol src/controllers src/interfaces src/oracle src/libs src/utils test
FORK_PATH := test/fork/**

# The heap benchmark's 100M+ gas swamps every other line of a snapshot/diff — keep it out of gas profiling.
SNAPSHOT_EXCLUDE := test/fork/HeapSettlementBenchmark.t.sol

.PHONY: help build sizes test fork-test fmt fmt-check lint coverage snapshot snapshot-diff slither solhint doc ci clean

help:
	@echo "Targets:"
	@echo "  build         forge build"
	@echo "  sizes         forge build --sizes"
	@echo "  test          forge test on the local suites (excludes test/fork/; no RPC, deterministic)"
	@echo "  fork-test     forge test on test/fork/ only; needs ETH_RPC_URL + DEPLOYMENT in .env, else self-skips"
	@echo "  fmt           forge fmt on tracked paths (local only; rewrites files)"
	@echo "  fmt-check     forge fmt --check on tracked paths (local only; CI does not fail on style)"
	@echo "  lint          forge lint"
	@echo "  coverage      forge coverage --ir-minimum --report summary"
	@echo "  snapshot      forge snapshot of the whole suite -> .gas-snapshot (fork suites skip without RPC; heap benchmark excluded)"
	@echo "  snapshot-diff same run, diffed against .gas-snapshot"
	@echo "  slither       slither . (needs slither installed)"
	@echo "  solhint       solhint 'src/**/*.sol' (needs node + solhint installed)"
	@echo "  doc           forge build --ast + regenerate docs/specs/api/ from NatSpec"
	@echo "  ci            build + lint + test  (what GitHub Actions runs on PRs)"
	@echo "  clean         forge clean"

build:
	forge build

sizes:
	forge build --sizes

test:
	forge test --no-match-path '$(FORK_PATH)'

fork-test:
	forge test --match-path '$(FORK_PATH)'

fmt:
	forge fmt $(FMT_PATHS)

fmt-check:
	forge fmt --check $(FMT_PATHS)

lint:
	forge lint

coverage:
	forge coverage --ir-minimum --report summary --no-match-path '$(FORK_PATH)'

# One snapshot for the whole suite: the fork suites run when ETH_RPC_URL + DEPLOYMENT are set and self-skip
# otherwise. The oracle seed (and the fork block, when an RPC is set) are resolved once, echoed, and passed
# into the run so every suite executes at the same values; export the echoed TEST_SEED / FORK_BLOCK to replay.
snapshot-diff: SNAP_FLAGS := --diff
snapshot snapshot-diff:
	@set -e; \
	seed="$${TEST_SEED:-$$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')}"; \
	block="$$FORK_BLOCK"; \
	if [ -z "$$block" ] && [ -n "$$ETH_RPC_URL" ] && [ -n "$$DEPLOYMENT" ]; then \
		block="$$(cast block-number --rpc-url "$$ETH_RPC_URL")"; \
	fi; \
	echo "TEST_SEED=$$seed FORK_BLOCK=$${block:-none} (export these to reproduce this run)"; \
	if [ -n "$$block" ]; then \
		FORK_BLOCK="$$block" TEST_SEED="$$seed" forge snapshot --no-match-path '$(SNAPSHOT_EXCLUDE)' $(SNAP_FLAGS); \
	else \
		TEST_SEED="$$seed" forge snapshot --no-match-path '$(SNAPSHOT_EXCLUDE)' $(SNAP_FLAGS); \
	fi

slither:
	slither .

solhint:
	solhint 'src/**/*.sol'

doc:
	forge build --ast
	python3 tools/gen_api_from_artifacts.py

ci: build lint test

clean:
	forge clean
