# Deployment runbook

The deploy script `DeployMarket.s.sol` is a starting point for a
wstETH/WETH lending market on the Morpho Blue fork; tune it before any real broadcast.

## What gets deployed

1. `MorphoBlueFork` — immutable core, `owner = msg.sender`.
2. `MarketAccessRegistry` — admin-controlled global allow/deny list.
3. `WstEthRateOracle` — wraps Lido's `stEthPerToken` as a Morpho-style oracle.
4. `AdaptiveCurveIrm` — Morpho Blue's adaptive-curve IRM (unmodified upstream).
5. `LidoMarketController` implementation + `OssifiableProxy` pointing at it.
6. `createMarket(params, controllerProxy, deleverageEnabled=true)` on the core, after
   `enableIrm` and `enableLltv(0.8e18)`.

## Pre-flight

- `MAINNET_RPC_URL` set (see `.env.example`).
- `forge --version` matches `.foundryref`.
- `git submodule update --init --recursive` is up to date.
- Deployer address is funded on the target chain.
- Confirm `WETH` and `WSTETH` addresses for the target chain (the script defaults are mainnet).
- Decide who holds `owner` on the core and `DEFAULT_ADMIN_ROLE` on the controller. Both
  default to `msg.sender` in the script; rotate immediately after deploy.

## Dry run (against a fork)

```sh
forge script script/DeployMarket.s.sol \
  --fork-url "$MAINNET_RPC_URL" \
  --sender "$DEPLOYER" \
  -vvv
```

This simulates the broadcast without sending transactions. Read the logged addresses.

## Broadcast

```sh
forge script script/DeployMarket.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --private-key "$PK" \
  --verify \
  --etherscan-api-key "$ETHERSCAN_API_KEY"
```

`--verify` works on supported networks; otherwise verify manually using the per-contract
constructor args printed in `broadcast/DeployMarket.s.sol/<chain>/run-latest.json`.

## Post-deploy checklist

The script puts `msg.sender` into **four** privileged roles. Rotate each:

- [ ] `core.setOwner(...)` → ops multisig (controls market creation, IRM/LLTV enable, fee setting).
- [ ] `MarketAccessRegistry` admin (`grantRole(DEFAULT_ADMIN_ROLE, ...)` + renounce on deployer).
- [ ] `OssifiableProxy` proxy admin (`proxy__changeAdmin(...)`) — controls controller upgrades.
- [ ] Controller `DEFAULT_ADMIN_ROLE` (`grantRole` + renounce on deployer) — controls market policy.

Then:

- [ ] Set `marketConfig` on the controller (`setMarketConfig(id, cfg)`).
- [ ] Set `deleverageHeapConfig` if defaults need overriding.
- [ ] Confirm the proxy is pointing at the expected `LidoMarketController` impl
      (`OssifiableProxy.proxy__getImplementation()`).
- [ ] Run the integration smoke tests against the deployed addresses.

## Open items

- No `script/Upgrade.s.sol` yet — controller upgrades via `OssifiableProxy.proxy__upgradeTo`
  are out of scope for this prototype.
- No multi-chain config files; copy this script and override addresses when targeting a new chain.
- Deterministic CREATE2 deploys are not wired in; the core has no deterministic address requirement.
