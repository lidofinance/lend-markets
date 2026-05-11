# Morpho Blue Fork Notes

`src/MorphoBlueFork.sol` is derived from Morpho Blue's core market contract.

Fork point:

- Upstream repository: `morpho-org/morpho-blue`
- Branch: `main`
- Commit: `1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a`
- Upstream core file: `src/Morpho.sol`

License note:

- At the fork point, upstream `src/Morpho.sol` is marked `GPL-2.0-or-later`.
- This forked core is marked `GPL-2.0-or-later`.

Main changes in `MorphoBlueFork.sol`:

- Adds optional per-market controller binding at market creation.
- Adds controller hook dispatch for market actions.
- Adds immutable per-market `fallbackExit` availability at market creation.
- Adds `fallbackExit` as a core settlement primitive.
- Keeps plain `createMarket(MarketParams)` for zero-controller markets with fallback disabled.
- Keeps Morpho-compatible market params, position shape, market shape, and market id derivation.

Non-core contracts such as controllers, registries, oracle adapters, proxy helpers, and tests are
not Morpho Blue core forks.
