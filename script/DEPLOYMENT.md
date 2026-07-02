# Deployment runbook

The deploy script `DeployMarket.s.sol` is a starting point for a
wstETH/WETH lending market on the Lido Blue fork; tune it before any real broadcast. The
activation parameters and suspects-registry bootstrap in the script are placeholders.

## What gets deployed

1. `LidoLend` — core implementation + `OssifiableProxy`; `initialize(owner = msg.sender)`.
2. `GuardianSignals` implementation + `OssifiableProxy`; `initialize(admin, guardians, quorum)`.
   The script ships a placeholder bootstrap (deployer is the sole guardian, `quorum = 1`); the
   registry rejects `quorum = 0`.
3. `WstEthRateOracle` — wraps Lido's `stEthPerToken` as a Morpho-style oracle.
4. `AdaptiveCurveIrm` — Morpho Blue's adaptive-curve IRM (unmodified upstream).
5. `LidoLendMarketController` implementation (constructor bakes in `core`; market id lives in storage) +
   `OssifiableProxy`; `initialize(marketId, admin, suspectsRegistry, activationConfig, settlementConfig)`.
6. `createMarket(params, controllerProxy, enableSettlement = true)` on the core. This owner-gated
   call auto-enables the IRM and LLTV (the standalone `enableIrm`/`enableLltv` steps were removed).
   The controller binding is immutable for the market.
7. `LidoLendERC4626` — single-market ERC-4626 wrapper over the market, reading the
   controller's settle view; constructor `(core, params, controllerProxy, name, symbol)`.

## Pre-flight

- `MAINNET_RPC_URL` set (see `.env.example`).
- `forge --version` matches `.foundryref`.
- `git submodule update --init --recursive` is up to date.
- Deployer address is funded on the target chain.
- Confirm `WETH` and `WSTETH` addresses for the target chain (the script defaults are mainnet).
- Review the **DRAFT** `activation` config in the script (delays, dust threshold, inflow reference,
  decay window, decay floor) — these are governance values.
- Decide the real guardian set + quorum for the suspects registry (the script uses the deployer
  as a placeholder sole guardian).
- Decide who holds `owner` on the core and `DEFAULT_ADMIN_ROLE` on the controller and registry.
  All default to `msg.sender` in the script; rotate immediately after deploy.

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

The script puts `msg.sender` into several privileged positions. Rotate each:

- [ ] `core` owner → ops multisig (controls market creation, IRM/LLTV enable, fee setting).
- [ ] Core `OssifiableProxy` admin (`proxy__changeAdmin(...)`) — controls core upgrades.
- [ ] `GuardianSignals` `DEFAULT_ADMIN_ROLE` (`grantRole` + renounce on deployer) — manages
      guardians and quorum.
- [ ] Registry `OssifiableProxy` admin (`proxy__changeAdmin(...)`).
- [ ] Controller `OssifiableProxy` admin (`proxy__changeAdmin(...)`) — controls controller upgrades.
- [ ] Controller `DEFAULT_ADMIN_ROLE` (`grantRole` + renounce on deployer) — manages the policy roles.

Then:

- [ ] Replace the placeholder guardian set + quorum on the registry (`addGuardian` / `removeGuardian`
      / `setQuorum`).
- [ ] Grant the controller policy roles to their real holders: `MANAGER_ROLE`, `FREEZER_ROLE`, `UNFREEZER_ROLE`, `PAUSER_ROLE`, `RESUMER_ROLE`. The deploy admin self-grants `MANAGER_ROLE` as `DEFAULT_ADMIN_ROLE` (its default admin) during deploy to seed the policy. Rotate it to the real holder and revoke the placeholder afterwards.
- [ ] Grant the registry override roles to their real holders: `RISK_STEWARD_ROLE`, `GOVERNANCE_ROLE`.
- [ ] Retune the activation config if the deploy-time placeholder needs changing (`setConfig`, or
      the fast `increaseActivationDelays`).
- [ ] Set the settlement config if defaults need overriding (`setSettlementConfig`), and the risk-steward Sybil
      lock (`setActivatingLock`) if used.
- [ ] Confirm each proxy points at the expected implementation
      (`OssifiableProxy.proxy__getImplementation()`).
- [ ] Record the deployed addresses in `deployed-<network>.toml` (the integration tests read it).
- [ ] Run the integration smoke tests against the deployed addresses.

## Open items

- No `script/Upgrade.s.sol` yet — controller/core/registry upgrades via
  `OssifiableProxy.proxy__upgradeTo` are out of scope for this prototype.
- No multi-chain config files; copy this script and override addresses when targeting a new chain.
- Deterministic CREATE2 deploys are not wired in; no contract has a deterministic address requirement.
