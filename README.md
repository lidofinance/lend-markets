# Lido Lending

Draft Morpho Blue fork for Lido Lending markets. The current implementation keeps Morpho-style
market accounting in an immutable core and puts Lido-specific policy in per-market controllers.

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
forge fmt src/MorphoBlueFork.sol src/controllers src/interfaces src/oracle test
```

## Source Layout

```text
src/
├── MorphoBlueFork.sol
├── controllers/
│   ├── LidoMarketController.sol
│   └── MarketAccessRegistry.sol
├── interfaces/
│   ├── IMarketAccessRegistry.sol
│   └── IMarketController.sol
├── oracle/
│   └── WstEthRateOracle.sol
└── proxy/
    └── OssifiableProxy.sol
```

## Architecture

`MorphoBlueFork` is the Morpho-compatible core:

- deployed once by constructor, with no core proxy or upgrade path;
- preserves upstream `MarketParams`, `Position`, `Market`, and market id derivation;
- preserves standard Morpho action signatures where possible;
- binds an optional controller once at market creation;
- binds `fallbackExit` availability once at market creation;
- calls controller hooks for controller-enabled markets.

`LidoMarketController` owns Lido policy:

- matured, activating, and dust collateral accounting;
- matured-only borrow capacity checks;
- freeze and pause flags;
- fallback eligibility and matured-collateral caps;
- market-level policy configuration.

`MarketAccessRegistry` owns shared address and position restrictions used by controllers.

## Fork Notes

`src/MorphoBlueFork.sol` is the only direct Morpho Blue core fork in this draft. See
`FORK_NOTES.md` for the fork point and the main contract-level changes.

## License

Repository source files use SPDX headers. The Morpho Blue fork point is pinned to upstream
`main` commit `1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a`, where `src/Morpho.sol` is marked
`GPL-2.0-or-later`. See `LICENSE` and `FORK_NOTES.md`.
