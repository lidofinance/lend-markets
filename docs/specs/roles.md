# Actors & Roles

Code-accurate map of every privileged action in a deployed market to its role, contract, intended holder, and impact class. The governance model it rests on — the non-custody rule, the impact classification, and the execution mechanisms — comes from ADR 004, ADR 006, and ADR 007. This is the detailed catalogue behind the [architecture](architecture.md) overview.

A single `LidoLend` core and a single `GuardianSignals` registry are shared across a deployment's markets, and each market adds its own controller, vault, and oracle. So the core-owner and guardian-registry roles below are deployment-wide — one holder for every market — while the controller roles exist once per market. Initially the deployer EOA holds every role and every proxy admin, and hands them to Lido governance before the market opens.

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

Every contract is deployed behind an `OssifiableProxy`: the shared `LidoLend` core and `GuardianSignals` registry (one each per deployment), plus each market's controller, vault, and oracle. The proxy admin is the upgrade authority and is a proxy-level surface, not an in-contract role.

| Surface | Powers | Class | Holder |
|---|---|---|---|
| Proxy admin (shared core and registry, plus each market's controller, vault, oracle) | `proxy__upgradeTo` / `proxy__upgradeToAndCall` (replace implementation), `proxy__changeAdmin` (transfer control), `proxy__ossify` (permanently lock by setting admin to `address(0)`) | C1 | Lido DAO (Voting + Dual Governance) |

An upgrade can change core mechanics and is therefore the only path that could introduce a custody-like power, so it sits behind the slowest authority — and behind Dual Governance for the stETH-exposed core, per ADR 007. A proxy can be ossified to give up upgradeability for good. The core is upgradeable, kept honest by a strong lender-exit delay (ADR 005). Initially the admin of all proxies is the deployer EOA, handed to governance with `proxy__changeAdmin` before the market opens.

## IRM

The interest-rate model (`AdaptiveCurveIRM`) is the one contract deployed bare — no proxy, no roles. It is bound into a market's `MarketParams` at `createMarket` and is immutable for that market: no role can swap it, and changing the curve means creating a new market. So the IRM carries no upgrade authority and no operational role of its own. The core flips `isIrmEnabled` on first use rather than through a dedicated lever.

## On-chain roles

### `LidoLend` core

The core authorizes its admin surface against a single in-contract `owner`. The deployed owner is the `LidoLendOwner` facade, wired in through the core's `setOwner`, which re-exposes each owner-only call behind a distinct role so the capabilities delegate independently. The core's `onlyOwner` is held by the facade, not the DAO directly.

| Role | Powers | Class | Holder |
|---|---|---|---|
| `MARKET_CREATOR_ROLE` | `createMarket` (controller-less and controlled) | C4 / C1 | Lido DAO |
| `FEE_MANAGER_ROLE` | `setFee` (≤ `MAX_FEE` = 25%), `setFeeRecipient` | C4 | Lido DAO |
| `DEFAULT_ADMIN_ROLE` | `transferLidoLendOwnership` (the only path to the core's `setOwner`), plus administers the two roles above | C1 | Lido DAO |

### Market controller

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles below | C1 | Lido DAO |
| `MANAGER_ROLE` | `setCollateralActivationConfig`, `setSettlementConfig`, `setSupplyCap`, `grantInstantActivation`, `revokeInstantActivation` | C4 | routine delay mechanism |
| `FREEZER_ROLE` | `freeze` | C3 | risk steward committee |
| `UNFREEZER_ROLE` | `unfreeze` | C3 | risk steward committee (splittable from the freezer) |
| `PAUSER_ROLE` | `pauseFor` (stops every controller hook) | C2 | emergency-seal committee, bounded |
| `RESUMER_ROLE` | `resume` | C2 | Lido DAO, slow |

Every `MANAGER_ROLE` lever is risk-increasing, so it takes the delay mechanism. `pauseFor` accepts an indefinite duration at the contract level, but the fast holder is an emergency-seal committee bounded to a finite pause — extending it or pausing indefinitely is a DAO action. Pause and resume sit on separate roles so the fast pauser can never resume.

### `RiskStewardDashboard`

One dashboard serves every market of a core, with the tighten-only risk levers gathered behind per-market stewards. Each lever reads a market's current activation config, enforces a one-directional change toward tighter policy, and writes the full config back through the controller's `MANAGER_ROLE` surface, which the dashboard holds.

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke `STEWARD_ADMIN_ROLE` | C1 | Lido DAO |
| `STEWARD_ADMIN_ROLE` | `addMarketSteward`, `removeMarketSteward` | C3 | Lido DAO |
| per-market steward | `increaseActivationDelays`, `increaseActivatingLock`, `revokeInstantActivation` | C3 | risk steward committee |

`STEWARD_ADMIN_ROLE` administers only the tighten-only C3 levers and cannot introduce a C0 or upgrade power, so its class follows a role-admin-tier convention over the bare impact definition.

A steward is appointed per market id, not as an AccessControl role, so the set scopes to one market. Every steward lever is one-directional toward tighter policy, so the committee can act fast.

### `GuardianSignals`

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles below | C1 | Lido DAO |
| `MANAGER_ROLE` | guardian seats (guardian + operator keys), quorum, and suspect window (`addGuardian`, `removeGuardian`, `setQuorum`, `setSuspectWindow`) | C1 / C3 | Lido DAO |
| `ACCESS_LIMITER_ROLE` | `ban` (bypass quorum) | C3 | risk steward committee |
| `ACCESS_RESTORER_ROLE` | `unban` | C4 | Lido DAO, timelocked |

The committee holds the fast risk-reducing side (`ban`) and governance the slow risk-increasing side (`unban`). Guardian-set membership stays DAO-only: a fast authority to shrink the set could quietly disable detection, and a bare count floor cannot tell a legitimate excision from sabotage.

### `ExitBookBase`

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles below | C1 | Lido DAO (Voting + Dual Governance) |
| `ALLOWLIST_MANAGER_ROLE` | the concrete book's source allow-list (`setMarketAllowed` / `setVaultAllowed`) | C4 | EasyTrack (objection window) |
| `FEE_MANAGER_ROLE` | `setServiceFee` (fee recipient and rate, capped at `MAX_SERVICE_FEE` = 25%) | C4 | Lido DAO |
| `RECOVERER_ROLE` | asset recovery (`recoverEther` / `recoverERC20` / `recoverERC721` / `recoverERC1155`) | C4 | Lido DAO |

The exit book is `AccessControl` set at construction, not behind an `OssifiableProxy` — its roles are its only privileged surface, with no separate upgrade authority. Each capability sits on its own role so it can be delegated independently: `ALLOWLIST_MANAGER_ROLE` splits the source allow-list off so enabling a market or vault is a routine risk-increase that can run through the EasyTrack objection window; `FEE_MANAGER_ROLE` sets the service fee (a cut of the filler's gross reward within the 25% cap, reaching no lender or borrower funds); `RECOVERER_ROLE` recovers tokens held by the contract. `DEFAULT_ADMIN_ROLE` only administers the roles. At construction `admin` holds all of them, and a deploy delegates each capability role to its final holder and revokes it from `admin`.

## Non-role actors

- **Guardian seats** — each committee seat is a persistent guardian key paired with a rotatable operator key, off-chain parties, not an AccessControl role. The operator key raises signals: `flag` and `suspect` add the seat as a flagger/reporter of an account (at `quorum` distinct seats a ban latches automatically), and `heartbeat` reports a last-scanned block for the liveness frontier. The guardian key governs the seat: `unflag`/`unsuspect` retract the seat's signals (never lifting a ban in effect) and `rotateOperator` swaps the operator key — the seat's flags, reports and heartbeat survive a rotation because they are keyed by the guardian id, not the operator key.
- **Borrower** — `supplyCollateral` and `repay` are permissionless add-value, `borrow` and `withdrawCollateral` are authorized and pass the controller's hook gates, `setSettlementLtv` is self-scoped with no role.
- **Lender** — `supply` and `withdraw` on the core, `deposit` / `mint` / `withdraw` / `redeem` / `fallbackExit` / `settle` on the vault, and `setAuthorization` to let the vault or an operator act over a core position.
- **Permissionless** — `liquidate`, `flashLoan`, `accrueInterest`.
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
