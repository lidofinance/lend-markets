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
- Adds immutable per-market `deleverage` availability at market creation.
- Adds `deleverage` as the core settlement primitive for fallback exit workflows.
- Keeps plain `createMarket(MarketParams)` for zero-controller markets with fallback disabled.
- Keeps Morpho-compatible market params, position shape, market shape, and market id derivation.
- **Upgradeable behind `OssifiableProxy`.** `DOMAIN_SEPARATOR` moved from `immutable` to storage so
  it reflects the proxy address (immutable would freeze the impl's address into bytecode and break
  EIP-712 isolation). The constructor petrifies the impl by writing `1` to a namespaced
  initializer slot (`keccak256("lido.lending.morpho-fork.initialized")`); the proxy's own slot
  starts at `0`, so the first call to `initialize(address newOwner)` through the proxy seeds
  `DOMAIN_SEPARATOR`, `owner`, and emits `SetOwner` exactly once. The initializer flag lives in
  the namespaced slot so it doesn't occupy a slot in the main linear layout. Original Morpho
  storage slots stay in place; the two fork-added mappings (`marketController`,
  `deleverageEnabled`) precede the new `DOMAIN_SEPARATOR`. New fields must be appended to keep
  upgrades layout-safe.

Non-core contracts such as controllers, registries, oracle adapters, proxy helpers, and tests are
not Morpho Blue core forks.
