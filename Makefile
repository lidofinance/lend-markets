# Shortcuts wrap the foundry commands documented in README/AGENTS.md.
# CI calls a subset of these so local and CI behavior stay in sync.

-include .env
export

FMT_PATHS := src/MorphoBlueFork.sol src/controllers src/interfaces src/oracle test
# Heap-benchmark gas runs into the 100M+ range and skews any gas snapshot / diff. Skip it.
SNAPSHOT_EXCLUDE := test/integration/HeapDeleverageBenchmark.t.sol

.PHONY: help build sizes test fork-test fmt fmt-check lint coverage snapshot snapshot-diff slither solhint ci clean

help:
	@echo "Targets:"
	@echo "  build         forge build"
	@echo "  sizes         forge build --sizes"
	@echo "  test          forge test (unit + benchmark, fork tests auto-skip without MAINNET_RPC_URL)"
	@echo "  fork-test     forge test --fork-url \$$MAINNET_RPC_URL"
	@echo "  fmt           forge fmt on tracked paths (local only; rewrites files)"
	@echo "  fmt-check     forge fmt --check on tracked paths (local only; CI does not fail on style)"
	@echo "  lint          forge lint"
	@echo "  coverage      forge coverage --ir-minimum --report summary"
	@echo "  snapshot      forge snapshot --no-match-path 'test/integration/HeapDeleverageBenchmark.t.sol'"
	@echo "  snapshot-diff forge snapshot --diff (against committed .gas-snapshot)"
	@echo "  slither       slither . (needs slither installed)"
	@echo "  solhint       solhint 'src/**/*.sol' (needs node + solhint installed)"
	@echo "  ci            build + lint + test  (what GitHub Actions runs on PRs)"
	@echo "  clean         forge clean"

build:
	forge build

sizes:
	forge build --sizes

test:
	forge test

fork-test:
	@test -n "$$MAINNET_RPC_URL" || (echo "MAINNET_RPC_URL not set" && exit 1)
	forge test --fork-url $$MAINNET_RPC_URL

fmt:
	forge fmt $(FMT_PATHS)

fmt-check:
	forge fmt --check $(FMT_PATHS)

lint:
	forge lint

coverage:
	forge coverage --ir-minimum --report summary --no-match-path '$(SNAPSHOT_EXCLUDE)'

snapshot:
	forge snapshot --no-match-path '$(SNAPSHOT_EXCLUDE)'

snapshot-diff:
	forge snapshot --diff --no-match-path '$(SNAPSHOT_EXCLUDE)'

slither:
	slither .

solhint:
	solhint 'src/**/*.sol'

ci: build lint test

clean:
	forge clean
