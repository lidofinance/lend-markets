# Actors & Roles

Code-accurate map of every privileged action in a deployed market to its role, contract, intended holder, and impact class. The governance model it rests on — the non-custody rule, the impact classification, and the execution mechanisms — comes from ADR 004, ADR 006, and ADR 007. This is the detailed catalogue behind the [architecture](architecture.md) overview.

A single `LidoLend` core is shared across a deployment's markets, and each market adds its own controller, vault, and oracle, plus a `GuardianSignals` registry it either deploys or shares. The registry is per guardian-set, not strictly per-market: a group of markets under one committee can share a single registry (its guardian set, quorum, and suspect window are registry-wide; bans stay keyed by market id), while a market needing a different set gets its own. So the core-owner roles below are deployment-wide — one holder for every market — the controller roles exist once per market, and the guardian-registry roles exist once per registry (shared by the markets on it). The deployer holds only transient setup authority during a deployment transaction; the completed deployment leaves it with no role or proxy-admin authority.

## Non-custody rule

No operational role can take, burn, redirect, confiscate, or permanently lock user value. A custody-like power can enter the system only through an explicit upgrade — never through a role grant, a parameter change, a pause, a gate, or a fallback lever. This is the single hard constraint every role below respects.

## Impact classification

Every privileged function is classified by impact. The class decides who may hold it and through which mechanism.

| Class | Effect | Owner / mechanism |
|---|---|---|
| C0 | take, burn, redirect, confiscate, or lock user value | not allowed as an operational lever |
| C1 | upgrade logic, or indirectly introduce a C0 power | Lido DAO (Voting, plus Dual Governance for stETH-exposed surfaces) |
| C2 | temporarily stop market functions | emergency-seal committee, time-limited |
| C3 | reduce risk or deny new service | risk steward or security gate, within bounds |
| C4 | increase risk or scale exposure | Lido DAO, or the routine delay mechanism within approved bounds |
| C5 | metadata or UI-only impact | bounded operator |

No C0 role exists in the deployed surface.

## Execution mechanisms

- **Lido DAO — Voting and Dual Governance.** The high-impact authority: upgrades, role administration, resume, market creation, and any risk increase outside approved bounds. Dual Governance gates the subset of actions that materially move Lido or stETH exposure (core upgrades, new markets, collateral-accounting and lender-exit changes, upgrade-admin changes), per ADR 007. The rest run through ordinary Voting.
- **Routine risk-increasing path.** Bounded, routine market-config increases run through an EasyTrack motion factory: an initiator opens a motion and execution follows an objection window (ADR 006).
- **Emergency seal.** A GateSeal-style committee can pause the market fast, for a finite time. It cannot resume, change parameters, or move assets, and its pause expiry is immutable.
- **Risk steward.** A committee (or bounded automation) makes immediate risk-reducing changes within governance-approved bounds. Any risk-increasing change routes back through the delay mechanism or the DAO.

## Proxy ownership and upgrades

The shared `LidoLend` core and `IrmRouter`, plus each market's controller, vault, oracle, and
`GuardianSignals` registry, are deployed behind an `OssifiableProxy`. The proxy admin is the upgrade
authority and is a proxy-level surface, not an in-contract role.

| Surface | Powers | Class | Holder |
|---|---|---|---|
| Proxy admin (shared core and IRM router, plus each market's controller, vault, oracle, `GuardianSignals`) | `proxy__upgradeTo` / `proxy__upgradeToAndCall` (replace implementation), `proxy__changeAdmin` (transfer control), `proxy__ossify` (permanently lock by setting admin to `address(0)`) | C1 | Lido DAO (Voting + Dual Governance) |

An upgrade can change core mechanics and is therefore the only path that could introduce a custody-like power, so it sits behind the slowest authority — and behind Dual Governance for the stETH-exposed core, per ADR 007. A proxy can be ossified to give up upgradeability for good. The core is upgradeable, kept honest by a strong lender-exit delay (ADR 005). Every completed deployment assigns all proxy admins to the DAO Agent; core and IRM-router proxy authority is transferred from the transient deployer before the backbone deploy returns, while per-market and oracle proxies are created with the Agent directly.

## IRM

Each market's immutable `irm` points to the proxied `IrmRouter`. The DAO Agent owns the router and its
proxy; EVMScriptExecutor manages per-market routes. `AdaptiveCurveIrm` is a bare protocol singleton whose
owner is the Agent and manager is EVMScriptExecutor; its per-market curve parameters are set at activation.

## On-chain roles

### `LidoLend` core

The core authorizes its admin surface against a single in-contract `owner`. The deployed owner is the
`LidoLendOwner` facade, wired in through the core's `setOwner`. The same fixed facade is the governance
entrypoint for per-market controller and guardian-registry calls: it resolves each target from the core by
market id. This lets delayed governance authorize one stable target and selector per action even as markets
are added. The core's `onlyOwner` is held by the facade, not the DAO directly.

| Role | Powers | Class | Holder |
|---|---|---|---|
| `MARKET_CREATOR_ROLE` | `createMarket` (controller-less and controlled) | C4 / C1 | EVMScriptExecutor |
| `FEE_MANAGER_ROLE` | `setFee` (≤ `MAX_FEE` = 25%), `setFeeRecipient` | C4 | Lido DAO Agent |
| `MARKET_MANAGER_ROLE` | per-market `setSupplyCap`, `unfreeze`, `setCollateralActivationConfig`, `setSettlementConfig`, and `setInstantActivation` through the resolved controller | C3 / C4 | EVMScriptExecutor |
| `GUARDIAN_MANAGER_ROLE` | guardian roster (`addGuardian`, `removeGuardian`, `replaceGuardian`), quorum, suspect window, and per-market `unban` through the resolved registry | C1 / C3 / C4 | EVMScriptExecutor |
| `DEFAULT_ADMIN_ROLE` | `transferLidoLendOwnership` (the only path to the core's `setOwner`), plus administers the capability roles above | C1 | Lido DAO |

The facade holds `MANAGER_ROLE` and `UNFREEZER_ROLE` on every controller, and `MANAGER_ROLE` and
`ACCESS_RESTORER_ROLE` on every guardian registry. Those downstream grants only let the facade dispatch:
callers must still hold the matching capability role on the facade. EVMScriptExecutor holds no direct
controller manager/unfreezer or guardian manager/restorer role, making the facade the sole stable EasyTrack
target for those actions.

### Market controller

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles below | C1 | Lido DAO |
| `MANAGER_ROLE` | `setCollateralActivationConfig`, `setSettlementConfig`, `setSupplyCap`, `setInstantActivation` | C4 | `LidoLendOwner` for EasyTrack governance actions; `RiskStewardDashboard` for bounded tighten-only actions |
| `FREEZER_ROLE` | `freeze` | C3 | risk steward committee |
| `UNFREEZER_ROLE` | `unfreeze` | C4 | `LidoLendOwner` (EasyTrack motion, objection window) |
| `PAUSER_ROLE` | `pauseFor` (stops every controller hook) | C2 | emergency-seal committee, bounded |
| `RESUMER_ROLE` | `resume` | C2 | Lido DAO, slow |

Every `MANAGER_ROLE` lever is risk-increasing, so it takes the delay mechanism. `freeze` is risk-reducing and stays with a fast committee; `unfreeze` restores service and is therefore risk-increasing, so it takes the routine delay mechanism — an EasyTrack motion with an objection window — rather than an immediate call. `pauseFor` accepts an indefinite duration at the contract level, but the fast holder is an emergency-seal committee bounded to a finite pause — extending it or pausing indefinitely is a DAO action. Pause and resume sit on separate roles so the fast pauser can never resume.

The operational roles are arrays, not single addresses: `LidoLendMarketBuilder.MarketRoles` carries
`managers` / `pausers` / `freezers` / `unfreezers` / `resumers` as `address[]`, so any role can have any
number of additional holders — an empty array grants nobody from configuration, and a zero entry reverts
(`ZeroRoleHolder`) as a config mistake rather than silently granting the zero address. Independently of those
arrays, the builder always grants the facade `MANAGER_ROLE` and `UNFREEZER_ROLE`. Production deployment
policy resolves `market.circuit_breaker_artifact` to a CircuitBreaker with the `EVMScriptExecutor` as its
admin and prepends it to `pausers`, so the activation motion can register the committee. Configured
`roles.pausers` entries are optional additional direct pausers. One CircuitBreaker may be reused across
several markets; the artifact reference remains explicit in each market config.
`AdaptiveCurveIrm` is a protocol-wide singleton (see IRM, above), so there is no per-market curve
owner/manager to wire at deploy — its owner/manager are set once with the backbone, and per-market curve
params are activation calldata, not a deploy input.

### `RiskStewardDashboard`

One dashboard serves every market of a core, with the tighten-only risk levers gathered behind per-market stewards. Each lever reads a market's current activation config, enforces a one-directional change toward tighter policy, and writes the full config back through the controller's `MANAGER_ROLE` surface, which the dashboard holds.

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke `STEWARD_ADMIN_ROLE` | C1 | Lido DAO |
| `STEWARD_ADMIN_ROLE` | `addMarketSteward`, `removeMarketSteward` | C3 | EasyTrack (objection window) |
| per-market steward | `increaseActivationDelays`, `increaseActivatingLock`, `revokeInstantActivation` | C3 | risk steward committee |

`STEWARD_ADMIN_ROLE` administers only the tighten-only C3 levers and cannot introduce a C0 or upgrade power, so its class follows a role-admin-tier convention over the bare impact definition.

A steward is appointed per market id, not as an AccessControl role, so the set scopes to one market. Every steward lever is one-directional toward tighter policy, so the committee can act fast.

The dashboard is a protocol-wide singleton, deployed once by `DeployProtocol` (via `ProtocolDeployer`) with `STEWARD_ADMIN_ROLE` → the EasyTrack executor and `DEFAULT_ADMIN_ROLE` → the DAO Agent. For its levers to write config it must additionally hold each market controller's `MANAGER_ROLE`; `LidoLendMarketBuilder` grants it that on every controller `LidoLendMarketFactory` deploys — the factory itself holds no role (it grants the new controller's `DEFAULT_ADMIN_ROLE` directly to its caller, the builder), and the builder holds that admin only transiently, for the duration of `buildMarket`. `MANAGER_ROLE` is broader than the tighten-only levers, so this trusts the dashboard's (non-upgradeable) code to only tighten.

### `GuardianSignals`

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles below | C1 | Lido DAO |
| `MANAGER_ROLE` | guardian set, quorum, and suspect window (`addGuardian`, `replaceGuardian`, `removeGuardian`, `setQuorum`, `setSuspectWindow`) | C4 | `LidoLendOwner` (EasyTrack motion, objection window) |
| `ACCESS_LIMITER_ROLE` | `ban` (bypass quorum) | C3 | risk steward committee |
| `ACCESS_RESTORER_ROLE` | `unban` | C4 | `LidoLendOwner` (EasyTrack motion, objection window) |

The committee holds the fast risk-reducing side (`ban`); `unban` is risk-increasing, so it takes the routine delay mechanism — an EasyTrack motion with an objection window (ADR 006) — rather than an immediate call. Guardian-set management (`addGuardian`/`removeGuardian`/`replaceGuardian`/`setQuorum`) runs through the same EasyTrack objection window, not a fast committee: a removal or quorum change is visible and vetoable before it takes effect, so it cannot quietly disable detection. `DEFAULT_ADMIN_ROLE` stays with the DAO and can re-grant `MANAGER_ROLE` for a direct action with no factory yet (e.g. `setSuspectWindow`).

The builder always grants the facade `MANAGER_ROLE` and `ACCESS_RESTORER_ROLE` in addition to the configured
guardian managers, so every registry remains reachable through the stable governance target.

### `ExitBookBase`

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles below | C1 | Lido DAO (Voting + Dual Governance) |
| `ALLOWLIST_MANAGER_ROLE` | the concrete book's source allow-list (`setMarketAllowed` / `setVaultAllowed`) | C4 | EasyTrack (allow-list motion) + Lido DAO Agent (standalone allow-list / de-list) |
| `FEE_MANAGER_ROLE` | `setServiceFee` (fee recipient and rate, capped at `MAX_SERVICE_FEE` = 25%) | C4 | Lido DAO |
| `RECOVERER_ROLE` | asset recovery (`recoverEther` / `recoverERC20` / `recoverERC721` / `recoverERC1155`) | C4 | Lido DAO |

The exit book is `AccessControlEnumerable` set at construction, not behind an `OssifiableProxy` — its roles are its only privileged surface, with no separate upgrade authority. Each capability sits on its own role so it can be delegated independently: `ALLOWLIST_MANAGER_ROLE` splits the source allow-list off so enabling a market or vault is a routine risk-increase that can run through the EasyTrack objection window; `FEE_MANAGER_ROLE` sets the service fee (a cut of the filler's gross reward within the 25% cap, reaching no lender or borrower funds); `RECOVERER_ROLE` recovers tokens held by the contract. `DEFAULT_ADMIN_ROLE` only administers the roles; the constructor grants it alone, and the capability roles are assigned after deploy. Exit books are optional: `MorphoExitBook` over lenders' core supply positions and `Erc4626ExitBook` over lenders' vault shares (the two ways a lender holds the same market). `DeployProtocol` deploys them (via `ProtocolDeployer`) only when the deploy config's `exit_books` flag is set — and wired with `ALLOWLIST_MANAGER_ROLE` → both the EasyTrack executor (for the separate allow-list motion) and the DAO Agent (for direct allow-list / de-list actions), and `FEE_MANAGER_ROLE` / `RECOVERER_ROLE` / `DEFAULT_ADMIN_ROLE` → the DAO Agent.

## Non-role actors

- **Guardians** — off-chain parties, not an AccessControl role; each guardian is a single committee address. A guardian raises signals with `flag` and `suspect` (once `quorum` distinct guardians flag an account, its ban latches automatically) and retracts them with `unflag`/`unsuspect` (which never lift a ban already in effect). `heartbeat` reports a last-scanned block for the liveness frontier, advancing it in the same call when it rises. A guardian may appoint one **delegate** with `setDelegate` — a hot key that acts on its behalf (one at a time); signals are stored under the guardian, so swapping the delegate keeps its standing.
- **Borrower** — `supplyCollateral` and `repay` are permissionless add-value, `borrow` and `withdrawCollateral` are authorized and pass the controller's hook gates, `setSettlementLtv` is self-scoped with no role.
- **Lender** — `supply` and `withdraw` on the core, `deposit` / `mint` / `withdraw` / `redeem` / `fallbackExit` / `settle` on the vault, and `setAuthorization` to let the vault or an operator act over a core position.
- **Permissionless** — `liquidate`, `flashLoan`, `accrueInterest`, and on the guardian registry `syncQuorumFrontier` (a fallback recompute of the liveness frontier — heartbeats normally advance it) and `prune` (clears the flags and reports left by removed guardians on an account; this lowers the flag count and can let a still-unlatched, quorum-derived ban lapse, but never lifts a latched ban).
- **Contract callers** — the core is the sole caller of `controller.on(...)` and of the IRM `borrowRate`, the vault acts on the core for lenders under their authorization, and the deployer performs the one-shot `initialize` and holds placeholder roles until handover.

## Routine risk-increasing actions

Each routine risk-increasing action is meant to run through a dedicated factory on the delay mechanism: an initiator opens a motion, and execution follows an objection window. The controller itself only sanity-checks the arguments — non-zero and ordered, bounded delays for `setCollateralActivationConfig`, and the basis-point ceilings (`sliceFloorBps ≤ BPS`, `ltvStepBps ≤ BPS`) for `setSettlementConfig`. The governance envelope — per-field bounds and no multi-field loosening in a single motion — lives on the factory, which decodes and checks the arguments before queueing.

Factory-gated actions and their parameters:

- **setCollateralActivationConfig** — `minActivationDelay`, `maxActivationDelay`, `maxDelayInflow`, `delayPerStrike`, `delayPerSuspect`, `activatingLockAmount`, `activatingLockDuration`, `minActivationAmount`, `maxGuardiansQuorumDelay`.
- **setSettlementConfig** — `sliceFloorBps`, `sliceFloorAssets`, `fullCutBelowCollateral`, `ltvStepBps`.
- **setSupplyCap** — `cap`.

The fast risk-reducing levers run with no objection window: the dashboard's `increaseActivationDelays`, `increaseActivatingLock`, and `revokeInstantActivation`, the controller's `freeze` and `unfreeze`, and the registry's `ban`.

## Role manifest

Before production, each privileged function and admin surface should appear in a role manifest carrying:

- the role name
- the contract and function selectors it guards
- the owner address and its type (EOA, multisig, quorum, DAO, immutable contract, or automation)
- the signer threshold for a multisig or quorum
- a signer-overlap report against other privileged roles
- the impact class
- the execution mechanism
- the delay or objection mechanism, if any
- the expiry, if any
- the revocation path
