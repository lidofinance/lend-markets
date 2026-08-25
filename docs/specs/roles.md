# Privileged Roles

This document records the initial privilege topology created by the production deployment scripts. A single `LidoLend` core serves all markets in a deployment, so core ownership is global. Each controller has its own roles. `GuardianSignals` roles belong to a registry, which may serve several markets.

The tables cover the integrated production deployment and its production prerequisite and add-on scripts for CircuitBreaker, oracles, new markets, guardian registries, optional IRMs, and Exit Books. Devnet and test helpers intentionally use broader local administrators and are outside this topology. Exact function parameters and errors belong to the [generated API reference](README.md#api-reference-generated).

## Onchain holders and governance routes

| Term | Meaning in this document |
|---|---|
| Lido DAO Agent | The onchain address that initially holds administration, ownership, and proxy-upgrade powers assigned to the DAO. |
| EVMScriptExecutor | The onchain executor that initially holds routine governance capabilities. |
| Market steward | An address appointed for one market in `RiskStewardDashboard`; it is not an AccessControl role holder. |
| Risk Steward Committee | The configured emergency address that initially holds `PAUSER_ROLE` on both Exit Books. |
| Registered controller pauser | An address registered for one target through CircuitBreaker; the registration is distinct from CircuitBreaker's immutable admin authority. |

The contracts see these addresses, not the governance process that controls them. Lido DAO Voting, Dual Governance, and EasyTrack are intended execution routes; their ownership, motion factories, delays, and objection rules are outside this repository's deployment and acceptance checks. An EasyTrack motion may execute through EVMScriptExecutor, but possession of an executor role does not prove that a bounded motion factory exists for that action.

## Impact classification

Impact classes are design labels, not limits enforced by the contracts. They describe the action being taken, not necessarily every action exposed by the role. A role may therefore have more than one class when tightening and loosening the same parameter have different effects.

| Class | Effect | Intended authority |
|---|---|---|
| C0 | take, burn, redirect, confiscate, or permanently prevent recovery of user value | not allowed as an operational action |
| C1 | upgrade logic, administer privileged roles, or introduce a C0 power | Lido DAO governance |
| C2 | temporarily stop controller-hooked actions | CircuitBreaker-operated emergency actor |
| C3 | reduce risk or deny new service | bounded security or risk-steward path |
| C4 | increase risk, restore service, or scale exposure | Lido DAO governance or an approved delayed path |
| C5 | metadata or UI-only impact | bounded operator |

No action listed below, other than proxy administration, can directly rewrite or redirect an underlying core or vault position. Proxy administration can change this implementation guarantee until the relevant proxy is ossified.

## Initial topology and verification

The production deployer and market factory use temporary setup authority, grant the holders listed below, and revoke their temporary roles before returning. Calling the permissionless market factory does not give the caller any role. The factory validates the exact controller and guardian-registry sets, including roles that must start empty. The standalone Exit Book script checks its required holders, sole pauser, and empty resumer set; acceptance later checks every listed Exit Book role exactly.

At deployment, the deployer, Lido DAO Agent, and EVMScriptExecutor must be distinct. An Exit Book pauser must also differ from all three. These checks do not constrain guardians, stewards, delegates, controller pausers, or later role assignments.

Acceptance checks the exact holder set for every AccessControl role listed below and rejects missing or extra holders. It also checks proxy admins, core ownership, and the router and Adaptive IRM owner-manager pairs.

## Proxy administration

The Lido DAO Agent is the initial proxy admin for the shared core and IRM router; every factory-deployed controller, vault, and guardian registry; and each standard oracle proxy. A shared guardian registry has one proxy admin even when several markets use it.

| Authority | Powers | Class | Initial onchain holder |
|---|---|---|---|
| `OssifiableProxy` admin | replace the implementation, transfer proxy administration, or irreversibly set the admin to `address(0)` | C1 | Lido DAO Agent |

Proxy administration is independent of implementation roles and can change their guarantees. `LidoLendOwner`, `RiskStewardDashboard`, `AdaptiveCurveIrm`, the optional `LinearKinkIrm`, `IrmConfigFactory`, `LidoLendMarketFactory`, CircuitBreaker, and the Exit Books are direct deployments rather than proxies.

## CircuitBreaker

The production deployment uses one CircuitBreaker instance for its controllers. EVMScriptExecutor is its immutable `ADMIN`, and CircuitBreaker is each controller's sole initial `PAUSER_ROLE` holder.

| Authority | Powers | Production assignment |
|---|---|---|
| CircuitBreaker `ADMIN` | change instance-wide pause and heartbeat durations within immutable bounds; register, replace, or remove a pauser for any target | EVMScriptExecutor |
| Registered controller pauser | maintain a live heartbeat and trigger one finite controller pause per registration | none after component deployment; governance-selected emergency actor after market activation |

A successful pause consumes that controller registration. CircuitBreaker does not validate a target or its pause permission when registration is written. The registered pauser cannot configure CircuitBreaker or resume the controller. The admin cannot exceed the immutable duration bounds or pause through CircuitBreaker without a live registration.

## Interest-rate management

In the standard market, the immutable `irm` field points to `IrmRouter`. The router selects an address for each market. `AdaptiveCurveIrm` is the standard model; `LinearKinkIrm` is optional. Each standard model references or stores a per-market configuration.

| Authority | Powers | Class | Initial onchain holder |
|---|---|---|---|
| Router or IRM owner | transfer ownership, replace the manager, and use the manager operations below | C1 / C4 | Lido DAO Agent |
| `IrmRouter` manager | route an uncreated market to any nonzero address without an allowlist or interface check; a live route must pass one `borrowRate` call | C4 | EVMScriptExecutor |
| Adaptive or Linear IRM manager | apply a compatible configuration contract to a market | C3 / C4 | EVMScriptExecutor |

The standard `IrmConfigFactory` permissionlessly deploys immutable configs and holds no role, but neither model requires a config to come from that factory. Adaptive rereads the selected config on each rate calculation, so a compatible mutable config can change its parameters without another manager call. Linear copies the returned parameters when the config is applied.

## AccessControl roles

### `LidoLendOwner` and core authority

The direct, non-upgradeable `LidoLendOwner` facade is the core's initial `owner`. It gates core-owner calls and dispatches controller and guardian-registry calls through separate capability roles.
The standard deployment sets the core-wide fee recipient to the Lido DAO Agent before transferring ownership to the facade.

| Role | Powers | Class | Initial onchain holder |
|---|---|---|---|
| `MARKET_CREATOR_ROLE` | create controller-less or controlled markets; fix the controller and settlement enablement at creation | C4 / C1 | EVMScriptExecutor |
| `FEE_MANAGER_ROLE` | set a market fee up to the core's 25% cap; set the core-wide fee recipient | C3 / C4 | EVMScriptExecutor |
| `MARKET_MANAGER_ROLE` | set supply cap, collateral-activation config, settlement config, and instant-activation callers; unfreeze a market | C3 / C4 | EVMScriptExecutor |
| `GUARDIAN_MANAGER_ROLE` | change a registry's guardians, quorum, and suspect window; clear a ban for selected market ids | C1 / C3 / C4 | EVMScriptExecutor |
| `DEFAULT_ADMIN_ROLE` | administer the facade roles; transfer core ownership while the facade is the core owner | C1 | Lido DAO Agent |

Controller and guardian calls use two checks: the caller must hold the facade capability, and the facade must hold the target contract's downstream role. EVMScriptExecutor holds the facade capabilities but no controller or guardian-registry role directly.

Transferring core ownership away disables the facade's core-owner calls. It does not revoke the facade's independent controller or guardian-registry roles. After transfer, the new core owner can call the core's `setOwner` directly.

Guardian roster, quorum, and suspect-window changes apply to the resolved registry and therefore affect every market sharing it. `unban` remains keyed by market id.

Neither the facade nor the core requires factory-produced components or the standard IRM router. `MARKET_CREATOR_ROLE` can therefore create a market outside the standard topology.

### Market controller

| Authority | Powers | Class | Initial onchain holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke controller roles | C1 | Lido DAO Agent |
| `MANAGER_ROLE` | set collateral-activation config, settlement config, supply cap, and instant-activation callers | C3 / C4 | `LidoLendOwner` and `RiskStewardDashboard` |
| `FREEZER_ROLE` | freeze the market | C3 | `RiskStewardDashboard` |
| `UNFREEZER_ROLE` | unfreeze the market | C4 | `LidoLendOwner` |
| `PAUSER_ROLE` | pause all controller hooks for a selected duration, including indefinitely | C2 / C3 | CircuitBreaker |
| `RESUMER_ROLE` | end a controller pause early | C4 | no initial holder |
| Instant-activation caller | make new collateral supplied through that caller active immediately, bypassing dust, the activation delay, and inflow throttling | C4 | none initially |

`LidoLendOwner` exposes the full manager surface to its capability holder. `RiskStewardDashboard` holds the same broad controller role, but its direct, non-upgradeable code exposes only bounded tightening, instant-activation revocation, and freeze.

These roles are granted before market creation, but the facade and dashboard cannot resolve this controller until market activation binds it in the core. Market activation does not change the role sets. No caller is enabled for instant collateral activation initially.

The initial topology has one unfreeze path through `LidoLendOwner`. A CircuitBreaker pause normally ends when its duration expires. An earlier resume is impossible until the Lido DAO Agent grants `RESUMER_ROLE` to a caller. As controller admin, the Agent can later change any of these role assignments, including granting `PAUSER_ROLE` to an address that may request an indefinite pause.

### `RiskStewardDashboard`

One direct, non-upgradeable dashboard serves the markets of one core. Steward membership is stored separately for each market id.

| Authority | Powers | Class | Initial onchain holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | administer dashboard roles | C1 | Lido DAO Agent |
| `STEWARD_ADMIN_ROLE` | add or remove a steward for a market | C3 | EVMScriptExecutor |
| Per-market steward | increase collateral-activation delays or activation lock, revoke instant activation, and freeze the market | C3 | none initially |

A steward acts only through the dashboard. The dashboard, not the steward, holds the controller roles.

### `GuardianSignals`

| Role | Powers | Class | Initial onchain holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke registry roles | C1 | Lido DAO Agent |
| `MANAGER_ROLE` | change the guardian set, quorum, and suspect window | C1 / C3 / C4 | `LidoLendOwner` |
| `ACCESS_LIMITER_ROLE` | ban one account for one market without guardian quorum | C3 | no initial holder |
| `ACCESS_RESTORER_ROLE` | clear a ban for one account and one market | C4 | `LidoLendOwner` |

Guardians and their delegates are privileged actors but are not AccessControl holders. A guardian controls its current delegate, so delegate identities are dynamic and are not pinned by deployment acceptance. Guardian actions and their shared-registry scope are specified in [Guardian Signals](guardian-signals.md).

| Authority | Powers | Class | Initial onchain holder |
|---|---|---|---|
| Guardian | appoint, replace, or clear its delegate; report signals and heartbeat progress under its own identity | C1 / C3 / C4 | configured guardian set |
| Current guardian delegate | report signals and heartbeat progress under the guardian's identity | C3 / C4 | none until appointed by a guardian |

### Exit Books

Each Exit Book is a direct, non-upgradeable `AccessControlEnumerable` contract. The two standard books receive the same initial holder sets.

| Role | Powers | Class | Initial onchain holder |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | grant and revoke Exit Book roles | C1 | Lido DAO Agent |
| `ALLOWLIST_MANAGER_ROLE` | allow or deny new requests for a Morpho market or ERC-4626 vault | C3 / C4 | Lido DAO Agent and EVMScriptExecutor, independently |
| `FEE_MANAGER_ROLE` | set the fee recipient and service share of the priority fee, capped at 25% | C4 | EVMScriptExecutor |
| `RECOVERER_ROLE` | recover Ether, ERC-20, ERC-721, or ERC-1155 tokens held by the book | C4 | Lido DAO Agent |
| `PAUSER_ROLE` | pause placement and fills across the whole book | C3 | configured Risk Steward Committee, sole initial holder |
| `RESUMER_ROLE` | resume placement and fills | C4 | no initial holder |

Delisting one source affects only new requests for that source. Pausing affects placement and fills for every source in the book; cancellation, reads, configuration, recovery, and direct source access remain available. A pause has no automatic expiry. Resume is impossible until the Lido DAO Agent grants `RESUMER_ROLE` to a caller.
