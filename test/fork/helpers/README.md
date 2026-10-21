# Morpho Vault V2 integration example

[MetaMorphoV2Integration.t.sol](../MetaMorphoV2Integration.t.sol) shows an external Morpho Vault V2 supplying into a deployed LidoLend market. It creates a disposable vault through the real Morpho factory **on the test fork only**, then configures a curator, allocator, adapter, caps and a liquidity route. It never broadcasts transactions or writes vault deployment artifacts.

**WARNING: [LidoLendV1AdapterV2](LidoLendV1AdapterV2.sol) is an unaudited, test-only fork. Do not deploy it with real funds. Upstream Morpho audits do not cover these modifications.** This example is not production deployment tooling or an exhaustive security review.

The adapter is based on Morpho's [MorphoMarketV1AdapterV2 at 425f6b1](https://github.com/morpho-org/vault-v2/blob/425f6b1fb3a1d25083a9515348bd5e7bd3ab9017/src/adapters/MorphoMarketV1AdapterV2.sol). It preserves tracked-share accounting, allocation identifiers and timelock logic. The changes are:

- pending interest uses LidoLend's generic `MorphoBalancesLib`, which calls `borrowRateView` through the market's IRM router instead of assuming an Adaptive Curve `rateAtTarget` getter;
- allocation and deallocation reuse their supplied `MarketParams`; `realAssets` loads them from core for each nonempty market;
- token approvals and transfers use the existing OpenZeppelin `SafeERC20` dependency;
- local ABI subsets replace the Vault V2 source dependency. The compiler target and adapter name differ.

Core, primary controller, oracle and IRM are bound from `deployed/<ARTIFACTS_DIR>/`. Only the multi-market scenario creates a second LidoLend market on that core, using a Solidity `MarketSpec` and the deployed Lido factory. It copies the primary market's dependencies and controller settings, with LLTV reduced by `1` in its WAD-scaled representation to give it a distinct market id. It reuses the primary market's immutable Adaptive Curve config and impersonates the deployed executor to configure the route, create the market through the owner facade and register its pauser. No secondary-market TOML or deployment artifact is needed.

The external vault factory comes from `external.morphoVaultV2Factory` in the run's network config. The Ethereum address is listed in [Morpho's official addresses](https://docs.morpho.org/developers/contracts/addresses/). A network config without that key (e.g. `hoodi`) skips the suite; a fork block before that factory exists fails explicitly. No local substitute is deployed.

## Run

With an archive RPC configured in `.env`:

```sh
make test-fork-provision FORK_PATH=test/fork/MetaMorphoV2Integration.t.sol
```

Or against an already-provisioned local Anvil:

```sh
RPC_URL=http://127.0.0.1:8545 ARTIFACTS_DIR=fork \
  forge test --match-path test/fork/MetaMorphoV2Integration.t.sol -vvv
```

Provisioning deploys only LidoLend resources. Full coverage requires the `weth-wsteth` and `usdy-usdt` market roles and a network config with the external factory. The default fork configuration provisions both. Without `usdy-usdt`, only the USDT scenario is skipped; the second WETH market is created by the multi-market scenario itself. Its fixture requires the primary WETH market to use the recorded Adaptive Curve IRM and have a registered pauser; it fails explicitly if the chosen secondary market id already exists. `TEST_SEED` and `FORK_BLOCK` support replay against the same deployment. Foundry transaction isolation resets Vault V2's transient accounting cache between separate user transactions; explicit multicalls and the solver helper test atomic composition within one transaction.

## What the scenarios establish

- Deposits and allocation reach LidoLend; borrowing uses the deployed collateral-price oracle.
- Pending-interest quotes agree with actual core accrual, including a switch from Adaptive Curve to Linear Kink. A focused adapter-boundary fuzz check verifies parameter reuse.
- Deposit, mint, withdraw and redeem are exercised through the vault, with independently calculated previews, token/share deltas, a nonzero core fee, performance fee and management fee.
- Failure of the oracle's rate source blocks borrowing but not liquid vault accounting and exits. A simulated rate loss followed by liquidation realizes bad debt and reduces vault share value.
- Direct allocator/sentinel deallocation, including zero-amount interest reconciliation, updates every allocation ID and transfers the expected assets. Full unwind, adapter removal and re-entry preserve accounting, including sub-unit share remnants.
- Zero and finite absolute/relative allocation caps reject entries without blocking exits. LidoLend's separate supply cap, freeze, pause and resume are exercised through the vault; a paused core still permits withdrawals covered by the vault's idle assets.
- Two WETH markets share one adapter: quotes add both positions, shared allocation IDs aggregate exposure, and batched rebalancing, liquidity-route changes and closing/reopening one market preserve accounting. A separate USDT/USDY vault exercises ERC-4626 operations and fees with a 6-decimal, no-return loan token. Each vault has one loan token; a foreign loan-token market is rejected.
- A `forceDeallocate`/`withdraw` multicall checks the configured penalty and that fees are charged once. A separate fully-utilized-market scenario executes supply, force deallocation and withdrawal atomically through [VaultV2AtomicExit](../MetaMorphoV2Integration.t.sol), using prefunded solver capital and a zero penalty, not a flash loan.
- With IRM reads and accrual still reverting, a timelocked `burnShares` followed by vault-level zero deallocation removes the failed position from accounting. The vault can then value and redeem its remaining idle assets. This is a write-off: the original core supply shares remain at the adapter and are no longer tracked, not recovered.

The happy paths use live WETH/wstETH and USDT/USDY, deployed price oracles and routed IRMs. Failure scenarios mock the wstETH rate source or IRM calls; the focused parameter-reuse check mocks the core parameter lookup. Fee settings, the secondary market and the Linear Kink route are test fixtures, not proposed launch parameters.

The full-utilization examples require the test borrower to become the settlement-queue root. The direct-lender settlement scenario settles that lender into collateral for exactly the cut the deployed settlement policy quotes, without changing the policy. The atomic solver scenario instead leaves the vault user with a direct core supply position while returning the solver's capital. The adapter itself does **not** implement `fallbackExit` or turn illiquid debt into WETH; force deallocation still needs market liquidity.

Coverage is intentionally an integration example, not certification of the forked adapter. It does not exhaustively test adapter governance, every token/market combination, or multi-market portfolio risk.
