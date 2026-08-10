# Privileged Roles

This document maps each privileged Lido Lend action to its contract, role, impact class, and intended holder. Start with [Architecture](architecture.md) for the system model and use the [generated API reference](README.md#api-reference-generated) for exact function parameters and errors.

A single `LidoLend` core serves all markets in one deployment. Core-owner roles therefore apply to every market. Controller roles exist once per market. `GuardianSignals` roles exist once per registry, and several markets may share a registry. The deployer has temporary setup authority only during deployment and retains no role or proxy-admin authority after handover.

## Holder and execution terms

| Term | Meaning in this document |
|---|---|
| Lido DAO Agent | The DAO-controlled address that holds high-impact administration and upgrade authority. |
| EVMScriptExecutor | The onchain executor used by approved DAO or EasyTrack actions. |
| EasyTrack | A delayed execution path in which an initiator creates a motion and execution follows an objection window. |
| Dual Governance | The additional governance gate for actions that materially affect Lido or stETH exposure. |
| CircuitBreaker | A contract that lets an approved emergency actor pause controller hooks for a bounded duration. |
| Risk steward | An appointed actor that may apply only the bounded, risk-reducing actions exposed by `RiskStewardDashboard`. |
| Protocol-wide risk steward | The intended emergency actor for an Exit Book, whose pause affects every source allowlisted in that book. |

## Non-custody rule

No operational role can seize or redirect a user's core or vault position, or permanently remove its recovery path. Protocol payouts go only to recipients selected by the relevant user or caller, or to a configured fee recipient, and remain within their documented caps. Recovery roles may move tokens already held directly by a recovery-enabled contract, but they cannot reach the underlying user position. Temporary pause or freeze controls may stop selected actions without transferring ownership. Only a contract upgrade can introduce a new custody-like power over user positions.

## Impact classification

Every privileged function is classified by impact. The class decides who may hold it and through which mechanism.

| Class | Effect | Owner / mechanism |
|---|---|---|
| C0 | take, burn, redirect, confiscate, or permanently prevent recovery of user value | not allowed as an operational action |
| C1 | upgrade logic, or indirectly introduce a C0 power | Lido DAO (Voting, plus Dual Governance for stETH-exposed surfaces) |
| C2 | temporarily stop market functions | CircuitBreaker-operated emergency actor, time-limited |
| C3 | reduce risk or deny new service | risk steward or another bounded security role |
| C4 | increase risk or scale exposure | Lido DAO, or the routine delay mechanism within approved bounds |
| C5 | metadata or UI-only impact | bounded operator |

No C0 role exists in the deployed surface.

## Execution mechanisms

| Mechanism | Use |
|---|---|
| Lido DAO Voting and Dual Governance | Upgrades, role administration, market creation, and risk increases outside approved bounds. Dual Governance adds a gate for actions that materially affect Lido or stETH exposure. |
| EasyTrack | Bounded routine changes. An initiator creates a motion and execution follows an objection window. |
| CircuitBreaker | Its registered pauser can trigger one finite pause and must maintain a live heartbeat. Its immutable admin configures bounded pause and heartbeat parameters and pauser registrations. Neither authority can resume a controller or move user assets. |
| Risk steward | Immediate, bounded risk reduction through the non-upgradeable dashboard. Risk increases return to EasyTrack or DAO governance. |

## CircuitBreaker authority

The standard deployment uses one direct CircuitBreaker for all factory-deployed controllers. Its immutable `ADMIN` is EVMScriptExecutor. The CircuitBreaker is the sole initial holder of each controller's `PAUSER_ROLE`, but it cannot use that role until its admin registers an operational pauser for the controller.

| Authority | Powers | Holder |
|---|---|---|
| CircuitBreaker `ADMIN` | Set `pauseDuration` and `heartbeatInterval` within immutable bounds; register, replace, or remove the pauser assigned to a controller | EVMScriptExecutor |
| Registered pauser | Maintain authorization with `heartbeat`; trigger one pause of its assigned controller, after which that assignment is removed | Governance-selected emergency actor |

The registered pauser cannot change CircuitBreaker parameters, choose the pause duration, resume a controller, or move assets. The admin cannot bypass the immutable parameter bounds.

## Proxy ownership and upgrades

The standard deployment puts the shared `LidoLend` core and `IrmRouter`, plus each factory-deployed market's controller, vault, oracle, and `GuardianSignals` registry, behind an `OssifiableProxy`. The proxy admin is the upgrade authority. It is a proxy-level permission, not an in-contract role.

| Surface | Powers | Class | Holder |
|---|---|---|---|
| Proxy admin (shared core and IRM router, plus each market's controller, vault, oracle, `GuardianSignals`) | `proxy__upgradeTo` / `proxy__upgradeToAndCall` (replace implementation), `proxy__changeAdmin` (transfer control), `proxy__ossify` (permanently lock by setting admin to `address(0)`) | C1 | Lido DAO Agent (Voting + Dual Governance) |

An upgrade can change core mechanics and could introduce a custody-like power. It therefore uses the slowest authority and, for the stETH-exposed core, Dual Governance under ADR 007. A proxy can permanently remove its upgrade authority through ossification. Deployment assigns every proxy admin to the Lido DAO Agent: the core and IRM-router permissions transfer from the temporary deployer, while market and oracle proxies name the Agent when created.

## IRM

In the standard factory deployment, each market's immutable `irm` address points to the proxied `IrmRouter`. The Lido DAO Agent owns the router and its proxy, while EVMScriptExecutor manages each market's route. The direct shared `AdaptiveCurveIrm` and optional `LinearKinkIrm` implementations have the Agent as owner and EVMScriptExecutor as manager. The permissionless `IrmConfigFactory` deploys or reuses immutable configurations by parameter hash; market activation resolves the selected configuration and applies it to the routed IRM. The core and `LidoLendOwner` do not enforce use of this router when a market is created with other valid parameters.

| Authority | Powers | Class | Holder |
|---|---|---|---|
| IRM stack owner | transfer ownership, replace the manager, and use the manager operations below | C1 / C4 | Lido DAO Agent |
| `IrmRouter` manager | select the IRM implementation for a market | C4 | EVMScriptExecutor |
| selected IRM manager | apply an immutable rate configuration to a market | C4 | EVMScriptExecutor |

## On-chain roles

### `LidoLendOwner` and core authority

The core checks its admin functions against one `owner` address. That owner is the `LidoLendOwner` contract, which also provides stable governance entrypoints for market controller and guardian-registry calls. It resolves each target from the core by market id. The DAO does not hold the core's `onlyOwner` permission directly.

| Role | Powers | Class | Holder |
|---|---|---|---|
| `MARKET_CREATOR_ROLE` | `createMarket` for controller-less and controlled markets; creation scales exposure and may bind high-impact policy | C4 / C1 | EVMScriptExecutor |
| `FEE_MANAGER_ROLE` | `setFee` (≤ `MAX_FEE` = 25%), `setFeeRecipient` | C4 | Lido DAO Agent |
| `MARKET_MANAGER_ROLE` | per-market `setSupplyCap`, `unfreeze`, `setCollateralActivationConfig`, `setSettlementConfig`, and `setInstantActivation` through the resolved controller | C3 / C4 | EVMScriptExecutor |
| `GUARDIAN_MANAGER_ROLE` | guardian roster (`addGuardian`, `removeGuardian`, `replaceGuardian`), quorum, suspect window, and per-market `unban` through the resolved registry | C1 / C3 / C4 | EVMScriptExecutor |
| `DEFAULT_ADMIN_ROLE` | `transferLidoLendOwnership` (the only path to the core's `setOwner`), plus administers the capability roles above | C1 | Lido DAO Agent |

The `C4 / C1` classification for market creation does not map to the two function overloads. A proposal is C4 when it only scales ordinary market exposure. It is handled as C1 when it introduces material Lido/stETH exposure or binds policy with upgrade-level impact.

For factory-deployed components, `LidoLendOwner` holds `MANAGER_ROLE` and `UNFREEZER_ROLE` on each controller, and `MANAGER_ROLE` and `ACCESS_RESTORER_ROLE` on each guardian registry. These grants only let that contract dispatch a call: the original caller must still hold the matching capability role on `LidoLendOwner`. EVMScriptExecutor holds none of those downstream roles directly, so the governance entry contract is the stable EasyTrack target.

### Market controller

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles below | C1 | Lido DAO Agent |
| `MANAGER_ROLE` | `setCollateralActivationConfig`, `setSettlementConfig`, `setSupplyCap`, `setInstantActivation` | C3 / C4 | `LidoLendOwner` for EasyTrack governance actions; `RiskStewardDashboard` for bounded tighten-only actions |
| `FREEZER_ROLE` | `freeze` | C3 | `RiskStewardDashboard`, called by the market's appointed steward |
| `UNFREEZER_ROLE` | `unfreeze` | C4 | `LidoLendOwner` through EasyTrack |
| `PAUSER_ROLE` | `pauseFor` (stops every controller hook) | C2 | CircuitBreaker |
| `RESUMER_ROLE` | `resume` | C2 | no holder |

The controller's `MANAGER_ROLE` is broader than either holder's public functions. Governance reaches it only through `LidoLendOwner`. A market steward reaches only the risk-reducing methods exposed by the non-upgradeable `RiskStewardDashboard`. The dashboard also holds `FREEZER_ROLE`, so the steward can call `freezeMarket` without holding a direct controller role. Only `LidoLendOwner.unfreezeMarket` restores service, through the EasyTrack objection window.

The standard factory's initial controller role assignments contain only the holders in the table above. The Lido DAO Agent is also the controller proxy admin. CircuitBreaker limits emergency pauses to a finite duration; because `RESUMER_ROLE` has no holder, normal recovery occurs when the pause expires. The Lido DAO Agent can change these assignments through `DEFAULT_ADMIN_ROLE`, including granting `RESUMER_ROLE` for an explicit early resume.

`AdaptiveCurveIrm` is a protocol-wide singleton, so there is no separate curve owner or manager for each market. Its owner and manager are assigned once for the shared deployment. The permissionless configuration factory holds no role. An authorized activation action resolves the market's immutable configuration from that factory and passes it to `applyIrmConfig`.

### `RiskStewardDashboard`

The standard deployment uses one dashboard for its factory-deployed markets. Its steward set is keyed by market id. The activation methods read the current configuration, require a change toward tighter policy, and write the complete configuration through the controller's `MANAGER_ROLE`. `freezeMarket` calls the controller through `FREEZER_ROLE`.

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke `STEWARD_ADMIN_ROLE` | C1 | Lido DAO Agent |
| `STEWARD_ADMIN_ROLE` | `addMarketSteward`, `removeMarketSteward` | C3 | EVMScriptExecutor through EasyTrack |
| per-market steward | `increaseActivationDelays`, `increaseActivatingLock`, `revokeInstantActivation`, `freezeMarket` | C3 | appointed risk steward |

Stewards are appointed in a set keyed by market id, not as protocol-wide AccessControl members. `STEWARD_ADMIN_ROLE` manages only that set and cannot introduce custody or upgrade authority. For each controller registered through the standard factory flow, the dashboard holds `MANAGER_ROLE` and `FREEZER_ROLE`. Because `MANAGER_ROLE` is broader than the dashboard's public methods, the boundary depends on the dashboard's non-upgradeable code exposing only bounded risk reductions.

### `GuardianSignals`

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles below | C1 | Lido DAO Agent |
| `MANAGER_ROLE` | guardian set, quorum, and suspect window (`addGuardian`, `replaceGuardian`, `removeGuardian`, `setQuorum`, `setSuspectWindow`) | C4 | `LidoLendOwner` through EasyTrack |
| `ACCESS_LIMITER_ROLE` | `ban` (bypass quorum) | C3 | no initial holder; the Lido DAO Agent may grant it later |
| `ACCESS_RESTORER_ROLE` | `unban` | C4 | `LidoLendOwner` through EasyTrack |

For a registry deployed through the standard factory flow, the Lido DAO Agent is the proxy admin and sole `DEFAULT_ADMIN_ROLE` holder. `LidoLendOwner` is the sole `MANAGER_ROLE` and `ACCESS_RESTORER_ROLE` holder. `ACCESS_LIMITER_ROLE` has no initial holder; granting it would let that holder bypass guardian quorum. `unban` and guardian-set management use an EasyTrack motion with an objection window. The Lido DAO Agent can change these role assignments through `DEFAULT_ADMIN_ROLE`.

Guardians and their delegates are privileged actors but are not AccessControl role holders. A registered guardian may set or replace its own delegate. The guardian or its current delegate may flag, unflag, suspect, unsuspect, and submit heartbeats under that guardian's identity. These actions can delay collateral activation or contribute to an account ban, but they cannot change committee configuration, clear a latched ban, or move assets. The exact quorum and lifecycle rules are in [Guardian Signals](guardian-signals.md).

### `ExitBookBase`

| Role | Powers | Class | Holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles below | C1 | Lido DAO Agent |
| `ALLOWLIST_MANAGER_ROLE` | allow or deny new requests for a source (`setMarketAllowed` / `setVaultAllowed`) | C3 / C4 | EVMScriptExecutor + Lido DAO Agent |
| `FEE_MANAGER_ROLE` | `setServiceFee` (recipient and service share of the priority fee, capped at `MAX_SERVICE_FEE` = 25%) | C4 | Lido DAO Agent |
| `RECOVERER_ROLE` | asset recovery (`recoverEther` / `recoverERC20` / `recoverERC721` / `recoverERC1155`) | C4 | Lido DAO Agent |
| `PAUSER_ROLE` | `pause` (stops placement and fills until governance resumes) | C3 | configured protocol-wide Risk Steward Committee (sole initial holder) |
| `RESUMER_ROLE` | `resume` | C4 | no initial holder; the Lido DAO Agent grants a governance resumer when needed |

An Exit Book is a direct, non-upgradeable `AccessControlEnumerable` contract. Its roles are its complete privileged surface. Delisting a source prevents new requests but does not disable existing requests. `FEE_MANAGER_ROLE` configures a service share of the priority fee within the 25% cap. `RECOVERER_ROLE` recovers tokens held by the contract, and `DEFAULT_ADMIN_ROLE` administers the other roles. Deployment assigns `ALLOWLIST_MANAGER_ROLE` to EVMScriptExecutor and the Lido DAO Agent; `FEE_MANAGER_ROLE`, `RECOVERER_ROLE`, and `DEFAULT_ADMIN_ROLE` to the Agent; and `PAUSER_ROLE` to the configured protocol-wide Risk Steward Committee.

The Exit Book pause is indefinite and blocks placement and fills. Cancellation, reads, configuration, recovery, and direct source access remain available; deadlines and fee ramps continue. One book spans all of its sources, so the same configured protocol-wide Risk Steward Committee is the sole initial `PAUSER_ROLE` holder on both books. `RESUMER_ROLE` starts empty. After a pause, the Lido DAO Agent grants an explicit governance resumer before service can resume.
