# Lido Lending

Draft Lido Lending markets built on a Morpho Blue fork. Morpho-style market accounting lives in a
vendored core (`lib/lido-lend`), and Lido-specific policy lives in a per-market controller in this
repo.

Status: draft, unaudited, not production-ready.

## Setup

Install Foundry, then fetch pinned dependencies. Current setup was checked with
`forge 1.5.1-stable`.

```sh
git submodule update --init --recursive
```

Build:

```sh
forge build
```

Run the local test suite:

```sh
forge test
```

Run mainnet-fork integration tests against real Lido contracts:

```sh
MAINNET_RPC_URL=<rpc-url> forge test --match-path 'test/integration/*.t.sol' --fork-url "$MAINNET_RPC_URL"
```

Format Solidity:

```sh
forge fmt src/LidoLendERC4626.sol src/GuardianSignals.sol src/controllers src/interfaces src/oracle src/libs src/periphery src/utils script test
```

## Repository Tooling

Most everyday commands are wrapped in a `Makefile`:

```sh
make help            # list available targets
make build           # forge build
make test            # forge test (unit + benchmark; fork tests auto-skip without RPC)
make fork-test       # forge test --fork-url $MAINNET_RPC_URL (copy .env.example to .env first)
make fmt-check       # forge fmt --check on tracked paths (CI gate)
make lint            # forge lint
make coverage        # forge coverage --ir-minimum --report summary
make slither         # static analysis (requires `slither` in PATH)
make solhint         # stylistic/security checks (requires `solhint` in PATH)
make ci              # everything CI runs on PRs: build + fmt-check + lint + test
```

Environment variables are documented in `.env.example`; copy it to `.env` and fill in
`MAINNET_RPC_URL` to enable fork tests locally.

CI pins Foundry via `.foundryref` (read by `.github/actions/repo-setup`); locally
`forge 1.5.1-stable` is the reference. Workflows live under `.github/workflows/`:
`ci.yml` (build/fmt/lint/test on every PR), `fork-test.yml` (mainnet-fork integration with
`MAINNET_RPC_URL` secret), `static.yml` (Slither + Solhint), `coverage.yml`,
`gas-diff.yml` (gas snapshot diff posted as PR comment), and `fuzz.yml` (deep fuzz on nightly cron).

To run the local pre-commit fmt check, point Git at the bundled hook:

```sh
git config core.hooksPath .githooks
```

## Source Layout

```text
src/
├── LidoLendERC4626.sol            # single-market ERC-4626 vault over the market
├── GuardianSignals.sol           # guardian-signal registry
├── controllers/
│   └── WethWstEthController.sol    # Lido policy: hooks, settlement queue, watermark, activation
├── interfaces/
│   └── IGuardianSignals.sol
├── libs/
│   ├── ActivationLib.sol
│   ├── MaxHeapLib.sol
│   └── SettlementQueueLib.sol
├── oracle/
│   └── WstEthRateOracle.sol
├── periphery/
│   └── LidoLendDepositGateway.sol  # ETH / stETH / WETH deposit zaps
├── proxy/
│   └── OssifiableProxy.sol
└── utils/
    └── PausableUntil.sol
```

## Architecture

The vendored core (`lib/lido-lend`, contract `LidoLend`) is the Morpho-compatible market.

- Upgradeable behind `OssifiableProxy`, with owner-gated market creation.
- Preserves upstream `MarketParams`, `Position`, `Market`, and market id derivation.
- Preserves standard Morpho action signatures where possible.
- Binds an optional controller and settlement availability once at market creation.
- Calls controller hooks for controller-enabled markets.

`WethWstEthController` owns Lido policy.

- Active, activating, and dust collateral accounting.
- Active-only borrow capacity checks.
- Freeze and pause flags.
- Settlement eligibility, the settlement queue, and per-borrower watermarks.
- Market-level policy configuration.

`GuardianSignals` owns shared address restrictions used by the controller.

## Fork Notes

The Morpho Blue fork is the vendored `lib/lido-lend` dependency. See `FORK_NOTES.md`, which points
to `lib/lido-lend/FORK_NOTES.md` for the fork point and core-level changes.

## License

Repository source files use SPDX headers. The Morpho Blue fork point is pinned in the `lib/lido-lend`
dependency to upstream `main` commit `1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a`, where `src/Morpho.sol`
is marked `GPL-2.0-or-later`. See `LICENSE` and `lib/lido-lend/FORK_NOTES.md`.
