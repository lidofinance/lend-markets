# Shortcuts wrap the foundry commands documented in README/AGENTS.md.
# CI calls a subset of these so local and CI behavior stay in sync.

-include .env
export

FMT_PATHS := src/LidoBlueERC4626.sol src/SuspectsRegistry.sol src/controllers src/interfaces src/oracle src/libs src/utils test
FORK_PATH := test/fork/**

.PHONY: help build sizes test test-local test-fork fmt fmt-check lint coverage snapshot snapshot-diff slither solhint doc ci clean

help:
	@echo "Targets:"
	@echo "  build         forge build"
	@echo "  sizes         forge build --sizes"
	@echo "  test          all tests, local + fork in one run; fork suites revert without the fork setup (ETH_RPC_URL + DEPLOYMENT)"
	@echo "  test-local    forge test on the local suites only (excludes test/fork/; no RPC)"
	@echo "  test-fork     forge test on test/fork/ only; the suites revert without the fork setup"
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
