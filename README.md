# Lido Lend Markets

Lido Lend is a family of isolated lending markets for established, low-risk looping trades, built on the [`lido-lend`](https://github.com/lidofinance/lido-lend) Morpho Blue fork. Each market is narrow by design, with strong exit paths and conservative controls that limit how quickly new collateral becomes borrowable.

The Morpho-style market accounting lives in that core, with the interest-rate model in [`lido-lend-irm`](https://github.com/lidofinance/lido-lend-irm). This repository — Lido Lend Markets — holds everything built on top: the per-market policy and contracts, the specifications, the deployment scripts, and the deployed-address registry.

