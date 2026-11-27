# Easy Track Factories

Review status: slop

Lido Lend runs many markets on one `LidoLend` core. Most changes to a live market are routine: a supply cap, a guardian, a pauser, a rate curve. Seven Easy Track factories let the **Lend Operational Committee** make these changes through motions instead of a full DAO vote. A motion takes effect unless LDO holders object.

This document describes the factories deployed on mainnet, built from `lidofinance/easy-track` commit `4caa911`. A factory works only after Aragon Voting registers it with its permissions. The first sections describe how motions run and what each one does. [Known properties](#known-properties) lists the accepted risks of this design. A report that describes a consequence of a listed root cause is a known issue.

Out of scope: Easy Track and Dual Governance internals beyond what reaches Lido Lend, proxy upgrades, and deployment configuration such as addresses, committee membership, and current parameter values. Dual Governance states, seals, ties, and emergency protection follow its [mechanism description](https://github.com/lidofinance/dual-governance/blob/main/docs/mechanism.md).

Role holders are in [Privileged Roles](roles.md). The mechanisms the motions change are in [Market Controller Policy](market-controller.md), [Guardian Signals](guardian-signals.md), [Settlement and Lender Exits](lender-settlement.md), and [Exit Books](exit-books.md).

## Actors

| Actor | Role here |
|---|---|
| Lend Operational Committee | A multisig, the `trustedCaller` of all seven factories. Only it can create their motions. |
| LDO holders | Object to a motion; enough objections reject it. |
| Anyone | Enacts a passed motion. Calls the permissionless `syncQuorumFrontier` and `prune` on a guardian registry. |
| EVMScriptExecutor | Executes enacted motions and holds the Lido Lend roles they use. |
| Aragon Voting | Owns the executor and administers Easy Track, outside Dual Governance. |
| Lido DAO Agent | Administers every Lido Lend AccessControl role, owns the IRMs, and is every proxy admin. It uses these powers through Dual Governance proposals. |
| Reseal Manager | A Dual Governance contract that initially holds `PAUSER_ROLE` and the only `RESUMER_ROLE` on every controller. |
| CircuitBreaker pauser | One address per market, registered through the CircuitBreaker admin, normally by a motion. It can pause that market once. |
| Market stewards, guardians | Act without a motion: stewards tighten activation rules and freeze a market; guardians flag accounts. |

Each privileged actor is trusted not to use its powers against users; [Known properties](#known-properties) states what follows if one does.

## How a motion runs

1. **Create.** The Lend Operational Committee submits calldata to a factory through Easy Track. The factory checks it against onchain state and builds the script. Easy Track stores the script's hash and snapshots the motion settings, a duration and an objection threshold that Aragon Voting sets.
2. **Object.** Any address that held LDO at the creation block can object until enactment. Objections reaching the threshold reject the motion.
3. **Enact.** After the duration, anyone can enact the motion. The motion does not expire. Easy Track rebuilds the script from the same calldata and requires it to match, so every factory check runs again at enactment. If a check fails, enactment reverts and the motion stays pending.
4. **Cancel.** The Lend Operational Committee or Aragon Voting can cancel a pending motion.

One motion performs one action, which may cover a list of markets or accounts. Grouped factories take `abi.encode(uint8 action, bytes payload)`; the action numbers in the tables below are part of that format. `LidoLendActivateMarket` takes `abi.encode(ActivationParams)`, and `LidoLendApplyIrmConfig` takes `abi.encode(bytes32 marketId, address irmConfig)`.

## Permissions

A motion's script can call only the `(target, method)` pairs registered for its factory. Easy Track checks targets and selectors, not arguments.

| Factory | Target | Methods |
|---|---|---|
| `LidoLendActivateMarket` | `AdaptiveCurveIrm` | `applyIrmConfig` |
| | `IrmRouter` | `setMarketIrm` |
| | `LidoLendOwner` | `createMarket(MarketParams, address, bool)`, `setFee` |
| | `RiskStewardDashboard` | `addMarketSteward` |
| | `CircuitBreaker` | `registerPauser` |
| | `LidoLendPreseeder` | `preseedMarket` |
| `LidoLendMarketManagerActions` | `LidoLendOwner` | `setInstantActivation`, `setMarketCollateralActivationConfig`, `setMarketSettlementConfig`, `setMarketSupplyCap`, `unfreezeMarket`, `setFee` |
| `LidoLendGuardianActions` | `LidoLendOwner` | `addGuardian`, `removeGuardian`, `replaceGuardian`, `setGuardiansQuorum`, `setGuardiansSuspectWindow`, `unbanGuardianSignals` |
| `LidoLendApplyIrmConfig` | `LidoLend` core | `accrueInterest` |
| | `AdaptiveCurveIrm` | `applyIrmConfig` |
| `LidoLendCircuitBreakerActions` | `CircuitBreaker` | `registerPauser`, `setPauseDuration`, `setHeartbeatInterval` |
| `LidoLendRiskStewardActions` | `RiskStewardDashboard` | `addMarketSteward`, `removeMarketSteward` |
| `LidoLendExitBookActions` | `MorphoExitBook` | `setMarketAllowed` |
| | `Erc4626ExitBook` | `setVaultAllowed` |

Calls to controllers and guardian registries go through the `LidoLendOwner` facade, which resolves them from the market id at call time. A market activated later therefore needs no new factory or permission.

The executor's roles cover more than these methods. It can also:
- create a controller-less market through `LidoLendOwner`, and set the core-wide fee recipient;
- route any router market, live or not yet created, to any IRM;
- apply an IRM config without accruing first;
- register a CircuitBreaker pauser for any target;
- preseed any market and vault that pass the preseeder's checks.

No factory builds these calls. Aragon Voting can reach them through the executor (K9). The Agent, as the roles' admin and the IRMs' owner, can use the same powers through Dual Governance.

### Invariants: what no motion can do

- Move, burn, or redirect a user position.
- Grant or revoke an AccessControl role, upgrade a proxy, or move core ownership.
- Set the fee recipient or create a controller-less market.
- Route a live market to another IRM, or apply an IRM config to a paused market.
- Pause, end a pause, or freeze directly. Motions only appoint the pauser or steward who can.

Motions can still change the conditions of existing positions: a quorum change bans at once every account whose strikes reach the new quorum, and lifts bans that rest only on the strike count (K6). A new activation or settlement config applies to existing lots and positions.

## Factories

Where a target enforces a rule itself, the factory usually checks it too, so an invalid motion fails early. The tables list what matters for reading a motion. Lists in a motion have no length cap and no duplicate check; a batch too large for the gas limit can be created but never enacted, so large batches are split.

### `LidoLendActivateMarket`

Creates a market, binds it to a controller deployed in advance, and makes it operable. `MarketParams`, the controller, and the settlement flag are fixed from then on.

```solidity
struct ActivationParams {
    MarketParams marketParams;     // loanToken, collateralToken, oracle, irm, lltv
    address irmConfig;             // initial AdaptiveCurveIrm config
    address controller;            // pre-deployed controller
    bool enableSettlement;
    address steward;               // initial market steward
    address pauserCommittee;       // initial CircuitBreaker pauser
    ILidoLendERC4626 preseedVault; // pre-deployed vault
    uint256 fee;                   // 1e18 = 100%
}
```

Calls, in order:
1. `AdaptiveCurveIrm.applyIrmConfig(marketParams, irmConfig)`
2. `IrmRouter.setMarketIrm(marketParams, AdaptiveCurveIrm)`
3. `LidoLendOwner.createMarket(marketParams, controller, enableSettlement)`
4. `RiskStewardDashboard.addMarketSteward(marketId, steward)`
5. `CircuitBreaker.registerPauser(controller, pauserCommittee)`
6. `LidoLendPreseeder.preseedMarket(marketParams, preseedVault)`
7. `LidoLendOwner.setFee(marketParams, fee)`, only when `fee != 0`

The rate model is set first because market creation asks the IRM for a rate. A revert in any call undoes the whole activation.

Checks:
- **Basic inputs.** Addresses are nonzero, and the market was never created. `marketParams.irm` is the `IrmRouter`, `lltv < 1e18`, and `fee <= 25%`.
- **`LidoLendMarketFactory` validation.**
  - The controller is bound to this core and market id.
  - It has the exact expected role holders, role admins, and proxy admin.
  - The vault matches the core, market, asset, and controller.
- **`LidoLendPreseeder` validation.**
  - The market and the vault are empty.
  - The vault is bound to this market and accepts the deposit.
  - The preseeder holds enough loan tokens.
- **Not checked:** the oracle, the tokens, the IRM config's contents, the controller's guardian registry and initial configuration, and stewards appointed earlier for the market id. See K2.

**`LidoLendPreseeder`** is a helper, not a factory. It holds loan tokens funded in advance and makes the first deposits into the new market and its vault. The market gets `1e9` shares. The vault gets at least `1e9` shares worth at least `1e6` base units. Both positions go to `0xdead`, which stops a first depositor from inflating the share price. Under the initial roles only the executor can preseed. The Lido DAO Agent is the preseeder's admin, can grant that role, and can recover any token it holds.

### `LidoLendMarketManagerActions`

Changes market policy through `LidoLendOwner`. Every action except `SetFee` needs the market to have a controller.

| # | Action | Payload | Factory checks | Notes |
|---|---|---|---|---|
| 0 | `SetInstantActivation` | `(bytes32 marketId, address caller, bool enabled)` | `caller` is nonzero; the status changes | The status belongs to the contract that calls the core. Collateral supplied through it is active at once, and bans still apply. A steward can revoke it. |
| 1 | `SetCollateralActivationConfig` | `(bytes32 marketId, CollateralActivationConfig cfg)` | the controller's bounds, with every duration at most 7 days; differs from current | Replaces the whole struct. Existing lots keep their base delay; the other fields apply to them at once. |
| 2 | `SetSettlementConfig` | `(bytes32 marketId, SettlementConfig cfg)` | both bps fields at most 10,000; differs from current | Replaces the whole struct. No effect on a market created without settlement. |
| 3 | `SetSupplyCap` | `(bytes32 marketId, uint256 cap)` | none | The cap counts accrued interest. A cap at or below supply blocks new supply, including vault deposits and the supply an Exit Book fill needs. `0` means no limit. A very large cap, the maximum included, can make the vault's `maxMint` and `mint` revert. |
| 4 | `UnfreezeMarkets` | `bytes32[] marketIds` | non-empty | Reopens borrowing, and lots past their unlock time activate at their next interaction. Does not end a pause. |
| 5 | `SetFee` | `(bytes32 marketId, uint256 fee)` | the market exists; at most 25%; differs from current | Accrues at the old fee first, without the controller, so it also works during a pause. Fee shares go to the core's fee recipient. |

### `LidoLendGuardianActions`

Changes a market's guardian registry through `LidoLendOwner`. Membership, quorum, and suspect window belong to the registry, so a motion naming one market changes every market that shares the registry. Only `UnbanAccounts` acts per market.

| # | Action | Payload | Factory checks | Notes |
|---|---|---|---|---|
| 0 | `AddGuardian` | `(bytes32 marketId, address guardian, uint256 newQuorum)` | not a guardian or delegate; fewer than 32 guardians; `1 <= newQuorum <= count + 1` | Adds, then sets the quorum, which may equal the new count. |
| 1 | `RemoveGuardian` | `(bytes32 marketId, address guardian, uint256 newQuorum)` | a guardian; `1 <= newQuorum < count` | Sets the quorum first, then removes. The last guardian cannot be removed. |
| 2 | `ReplaceGuardian` | `(bytes32 marketId, address oldGuardian, address newGuardian)` | old is a guardian; new is neither a guardian nor another guardian's delegate | One seat changes hands; count and quorum stay. |
| 3 | `SetGuardiansQuorum` | `(bytes32 marketId, uint256 quorum)` | `1 <= quorum <= count`; differs from current | |
| 4 | `SetSuspectWindow` | `(bytes32 marketId, uint256 window)` | at most 30 days; differs from current | |
| 5 | `UnbanAccounts` | `UnbanRequest[]`, each `{address account, bytes32[] marketIds}` | lists non-empty | Clears the ban and strikes of each listed pair. Suspect reports stay. |

A departed guardian's signals count until pruned. K6 lists the effects of a quorum change and the follow-up calls a guardian motion needs.

### `LidoLendApplyIrmConfig`

Replaces the rate curve of a live market in two calls: `LidoLend.accrueInterest`, then `AdaptiveCurveIrm.applyIrmConfig`. The accrual charges the period up to the motion at the old curve. The factory requires:
- a nonzero config;
- a market that the `IrmRouter` routes to `AdaptiveCurveIrm`;
- a controller;
- no pause, since a paused controller rejects the accrual.

The IRM reads the config on every rate calculation, and the config's contents are not checked (K1).

### `LidoLendCircuitBreakerActions`

Manages the CircuitBreaker instance shared by all Lido Lend controllers.

| # | Action | Payload | Factory checks | Notes |
|---|---|---|---|---|
| 0 | `RegisterPauser` | `(bytes32 marketId, address pauser)` | for a nonzero pauser, CircuitBreaker holds the controller's `PAUSER_ROLE` | Replaces the market's pauser; zero removes it. A pause consumes the registration. Registering also restarts the pauser's heartbeat. |
| 1 | `SetPauseDuration` | `uint256` seconds | within the bounds fixed at CircuitBreaker's deployment | Applies to every market, from its next pause. |
| 2 | `SetHeartbeatInterval` | `uint256` seconds | within the bounds fixed at deployment | Applies to every pauser, from its next heartbeat, registration, or pause. |

### `LidoLendRiskStewardActions`

| # | Action | Payload | Factory checks | Notes |
|---|---|---|---|---|
| 0 | `AddRiskSteward` | `(bytes32 marketId, address steward)` | nonzero; not yet a steward | Works for a market id before activation; the steward gains its powers when the market is created. |
| 1 | `RemoveRiskSteward` | `(bytes32 marketId, address steward)` | is a steward | What the steward already did stays. |

A steward can do five things:
- raise the activation delays;
- raise the activating lock;
- raise the deposit floor;
- revoke instant activation;
- freeze the market.

It cannot loosen anything or unfreeze.

### `LidoLendExitBookActions`

| # | Action | Payload | Factory checks | Notes |
|---|---|---|---|---|
| 0 | `SetMorphoExitBookAllowed` | `(MarketParams[] markets, bool allowed)` | non-empty; each market exists | One value for every entry. |
| 1 | `SetErc4626ExitBookAllowed` | `(address[] vaults, bool allowed)` | non-empty; each vault nonzero | One value for every entry. |

Allowing a source opens it for new requests. Denying it stops new requests only; existing requests can still be cancelled or filled.

## Pauses and Dual Governance

A pause stops every core action that calls the controller: supply, withdrawal, collateral supply and withdrawal, borrowing, repayment, liquidation, settlement, and explicit accrual. Interest keeps running and is booked at the next accrual ([Market Controller Policy](market-controller.md#freeze-and-pause)).

| Party | Can |
|---|---|
| Registered CircuitBreaker pauser | Pause a market once, for the current pause duration, while its CircuitBreaker heartbeat is live. |
| Reseal Committee, through Dual Governance and the Reseal Manager | Make a running finite pause indefinite, in any Dual Governance state except Normal. |
| Tiebreaker, through Dual Governance and the Reseal Manager | Resume a paused controller, only in a tie. |
| Lido DAO Agent, through a Dual Governance proposal | Grant or revoke `PAUSER_ROLE` and `RESUMER_ROLE`. It can therefore start, extend, or end a pause, or remove CircuitBreaker's ability to pause a market. |

A finite pause ends on its own. CircuitBreaker cannot end, shorten, or extend one.

## Known properties

Each entry names a root cause, what follows from it, and what limits it.

> [!NOTE]
> **K1. The Lend Operational Committee is trusted with parameter values.** Accepted risk.
> - **Root cause:** a factory enforces the range a target accepts and checks the inputs for consistency. It does not judge whether a value is safe for the market.
> - **Consequences:** within those ranges, a motion can still be unsafe for users. For example:
>   - an extreme or near-zero rate curve. An extreme rate held over a long gap, such as a pause, can also exceed the range of the core's interest accounting, after which accrual reverts;
>   - an IRM config that later reverts or changes its answers. A reverting config cannot be replaced by a motion, because `ApplyIrmConfig` accrues first;
>   - an unfreeze during an incident, or an unban of a flagged account;
>   - an unsuitable steward, pauser, or guardian, or a quorum of one;
>   - looser activation rules, or a settlement config that closes whole positions;
>   - a supply cap of zero (no limit) or of one, or a 25% fee.
>
>   When the committee removes an appointee, that also takes a motion, so an unsuitable steward, pauser, or guardian keeps its powers until the motion is enacted or the Agent acts.
> - **Trust note:** the steward and pauser roles add protection only to the extent that their holders are independent of the committee, and they act without a motion.
> - **Mitigations:**
>   - Every motion is public for the motion duration, and LDO holders can reject it.
>   - The committee is a multisig, so no single signer can create a motion.
>   - Stewards and the pauser can react to a bad change without a motion.
>   - Through a Dual Governance proposal, the Agent can apply a new IRM config directly, replace the IRM manager, and revoke the executor's AccessControl roles.

> [!NOTE]
> **K2. Activation trusts the contracts it is given.** Accepted risk.
> - **Root cause:** the activation checks read the candidate contracts' own answers. A contract that answers like a genuine controller, vault, registry, or IRM config passes. The market's parameters and its controller binding are then fixed. The controller and oracle change only by an Agent upgrade of their proxies.
> - **Consequences:**
>   - A market created with a wrong oracle, token, controller, registry, or config puts its lenders' funds and its collateral at risk.
>   - A contract that imitates a vault can pull the preseeder's loan tokens up to the allowance the preseeder leaves, which can grow across activations.
>   - Stewards appointed for the market id before activation keep their powers.
> - **Mitigations:** apart from the preseeder's balance and the pauser's heartbeat on its other markets, activation affects only the new market. Before a motion, the deployment's acceptance checks and the committee verify its inputs offchain, as the table lists, and LDO holders can object. Lenders can inspect a market before they supply.
>
> | Input | Verified offchain |
> |---|---|
> | Tokens, oracle, LLTV | The intended ones; the oracle prices this pair. |
> | Controller and vault | Deployed by `LidoLendMarketFactory` with the expected implementation; no instant-activation caller; intended initial cap and configs. |
> | Guardian registry | Deployed by `LidoLendMarketFactory` or already in use, with the intended guardians and quorum. |
> | IRM config | Created by `IrmConfigFactory`, which anyone can call, and returns the reviewed curve. |
> | Stewards of the market id | None appointed before activation. |
> | Steward, pauser, instant-activation caller, Exit Book vault | The intended address. |

> [!NOTE]
> **K3. Enactment re-checks the rules, not the decision.** Accepted risk.
> - **Root cause:** Easy Track runs the factory checks again at enactment but does not ask whether the motion is still wanted.
>   - Anyone can enact a passed motion, at any time, in their own transaction.
>   - A motion that fails a check stays pending and can be enacted once the check passes again.
> - **Consequences:**
>   - A passed motion can overwrite a change made after it was created: an unfreeze can lift a later freeze, a config can undo a steward's tightening, an unban can clear a later ban, and a registration can re-arm a pauser.
>   - The enactor chooses the moment and the order, and can act right after the motion in the same transaction, for example borrowing after an unfreeze or pausing after a rate change.
>   - An activation that failed for lack of preseeder funds becomes enactable again once anyone tops the preseeder up.
>   - A `SetFee` enacted during a pause books the paused interest at the curve in force at that moment. A config applied later cannot reprice it.
> - **Mitigations:**
>   - Pending motions are public.
>   - The committee cancels a motion it no longer wants.
>   - Stewards can act again after enactment, and a pauser can be registered again.

> [!NOTE]
> **K4. Other actors can make a pending motion fail.** Accepted risk.
> - **Root cause:** the enactment re-check reads state that guardians, stewards, pausers, the Agent, and other motions can change.
> - **Consequences:** enactment reverts and the motion stays pending. Only time is lost; a failed motion changes nothing. Examples:
>   - another guardian blocks `AddGuardian` or `ReplaceGuardian` by delegating to the new address;
>   - a pause blocks `ApplyIrmConfig`;
>   - a steward's change makes an instant-activation or config motion redundant;
>   - another guardian motion changes the count or quorum;
>   - an emptied preseeder blocks an activation.
> - **Mitigations:** the committee submits a new motion, or the Agent makes most of these changes directly through Dual Governance.

> [!NOTE]
> **K5. Easy Track is a shared, pausable channel.** Accepted risk.
> - **Root cause:** Lido Lend motions share Easy Track's pause, objection rules, and pending-motion cap with every Lido factory.
> - **Consequences:**
>   - An Easy Track pause stops creation and enactment. Aragon Voting or Easy Track's EmergencyBrakes multisig can trigger it, and the holder of the unpause role, Aragon Voting, lifts it.
>   - A full queue stops creation.
>   - Objections reaching the threshold reject a motion. An objection after the duration counts if it lands before enactment.
>   - Any of these can delay a protective motion such as an unfreeze, an unban, or a pauser registration.
> - **Mitigations:** freezing and pausing need no motion. The Agent can make most changes through Dual Governance; CircuitBreaker settings stay with the executor (K8).

> [!NOTE]
> **K6. Guardian motions change shared registry state and leave cleanup to follow-up calls.** Accepted risk.
> - **Root cause:** a registry's membership, quorum, suspect window, and quorum frontier are shared by its markets. Guardian motions do not recompute the frontier or prune old signals, and among motions only `UnbanAccounts` lifts latched bans.
> - **Consequences:**
>   - A motion for one market changes every market on the registry.
>   - A quorum cut bans at once every account whose strikes reach it; a raised quorum lifts bans that rest only on the strike count.
>   - A removed guardian's signals and latched bans stay.
>   - After a removal, replacement, or quorum cut, the frontier can stop advancing, so collateral activation waits for the `maxGuardiansQuorumDelay` fallback.
>   - The stored frontier never moves back: progress made by a removed guardian's past heartbeats, or under a lower quorum, stays.
> - **Mitigations:** anyone can call `syncQuorumFrontier` and `prune` after a guardian motion, `UnbanAccounts` clears latched bans, and markets that need independent guardians use separate registries.

> [!NOTE]
> **K7. A pause stops controller-checked actions while interest runs, and only Dual Governance ends it early.** Accepted risk.
> - **Root cause:** a pause blocks every action that calls the controller, repayment and liquidation included. Initially, the only `RESUMER_ROLE` is held by the Reseal Manager, which acts only for Dual Governance. A new pauser can be registered during a pause.
> - **Consequences:**
>   - Pauses can be chained, one registration at a time.
>   - Outside the Normal state a pause can become indefinite (K11).
>   - Borrowers cannot repay or add collateral during a pause. Liquidation reopens the moment it ends, and the first accrual charges the whole pause at a rate that adapted over it. If the collateral price falls during a long pause, liquidations at the end can leave bad debt.
>   - One address registered for several markets can pause each of them, and one missed CircuitBreaker heartbeat disarms it for all.
>   - A re-arm motion created after a pause starts lands before the pause ends only while the motion duration is shorter than the pause; nothing enforces this.
> - **Mitigations:**
>   - A CircuitBreaker pause lasts a duration bounded at deployment and ends on its own.
>   - Each registration is single-use and needs a motion, or an Aragon Voting action (K9).
>   - A market's IRM config can cap the borrow rate, which bounds the interest a pause adds.
>   - The Agent can grant `RESUMER_ROLE`, or revoke CircuitBreaker's `PAUSER_ROLE`, through Dual Governance.

> [!NOTE]
> **K8. Lido Lend's CircuitBreaker is administered by the executor, not the Agent.** Accepted risk.
> - **Root cause:** the CircuitBreaker's `ADMIN` is immutable and set to the EVMScriptExecutor. By contrast, the Lido core protocol's CircuitBreaker is administered by the Agent.
> - **Consequences:**
>   - Pause duration, heartbeat interval, and pauser registration follow Easy Track and Aragon Voting, not Dual Governance.
>   - Moving the admin needs a new CircuitBreaker, new activation and CircuitBreaker factories, a new `LidoLendMarketFactory`, and Agent proposals that move `PAUSER_ROLE` on every controller.
>   - If Easy Track moves to a new executor, Lido Lend motions fail until the Agent grants it the roles. CircuitBreaker motions, and the pauser step of activation, keep failing, because the `ADMIN` stays the old executor.
> - **Mitigations:** the duration bounds are immutable, and the Agent can revoke CircuitBreaker's `PAUSER_ROLE` on any controller through a Dual Governance proposal, which Aragon Voting submits.

> [!NOTE]
> **K9. Aragon Voting controls Easy Track and the executor outside Dual Governance.** Accepted risk.
> - **Root cause:** Aragon Voting owns the EVMScriptExecutor and administers Easy Track directly. Neither is behind Dual Governance; this follows the Lido governance model, which keeps Easy Track outside it.
> - **Consequences:**
>   - An Aragon vote can point the executor at Voting itself. From then on Voting uses every executor role without a motion, a Dual Governance timelock, or a veto; the vote's own duration is the only delay. That covers pausing markets, rerouting a market's IRM, setting fees and the fee recipient, unfreezing, unbanning, changing guardians, stewards, allowlists, and activation rules, and creating markets.
>   - Setting the fee recipient does not accrue first, so the new recipient also collects the fees earned since each market's last accrual. With a 25% fee and an extreme rate, a recipient of Voting's choice receives a quarter of the accrued interest as supply shares, which it can redeem for free liquidity like any lender.
>   - It can hand the executor to another owner or have it renounce its roles, so the change outlasts the vote.
>   - It can add factories, change motion settings, cancel motions, and mint LDO.
>   - It can move tokens the Agent holds through Lido's Finance app, including Lido Lend fees once the Agent withdraws them.
>   - Lido Lend users' exit window is the Aragon vote itself.
> - **Limits:** without a Dual Governance proposal, Voting cannot do any of these:
>   - upgrade a proxy;
>   - grant roles, or revoke roles that others hold;
>   - change an oracle;
>   - end a pause;
>   - move user positions directly.
> - **Mitigations:** every Aragon vote is public before it executes, and Lido Lend is governed by the same LDO holders as the Lido protocol. Dual Governance proposals also come from Voting, so they offer no separate remedy here; the check on a Voting decision is the vote itself.

> [!NOTE]
> **K10. Dual Governance does not see stETH held in Lido Lend.** Accepted risk.
> - **Root cause:** the Dual Governance escrow accepts stETH and wstETH from their holders. wstETH posted as Lido Lend collateral sits in the core. Apart from flash loans, which must be repaid in the same transaction, it moves only when the controller allows it.
> - **Consequences:**
>   - That collateral cannot be locked in the veto escrow, or withdrawn to exit before a proposal executes, while the market is paused. A freeze has the same effect for a borrower with debt until it repays in full.
>   - Pauses through the executor (K9) can coincide with a Dual Governance proposal.
>   - The core also lends its wstETH in fee-free flash loans, even during a pause. That adds to the liquidity available for briefly inflating veto-signalling support with borrowed stETH, which Dual Governance lists among its known risks.
> - **Mitigations:**
>   - The share of stETH held as Lido Lend collateral bounds the effect.
>   - Outside a pause or freeze, borrowers can withdraw their excess active collateral. Collateral still activating is held by the activating lock, set to at most 7 days, which new deposits restart.
>   - No Lido Lend controller is registered as a Dual Governance sealable withdrawal blocker, so a Lido Lend pause cannot trigger a tie.

> [!NOTE]
> **K11. Dual Governance states reach Lido Lend.** Accepted risk.
> - **Root cause:** the controllers grant their pause roles to one Reseal Manager, and Agent repairs go through the Dual Governance timelock.
> - **Consequences:**
>   - Once Dual Governance leaves Normal, the Reseal Committee can make a running pause indefinite, and the same states hold back Agent proposals. Locking the first-seal share of stETH in the escrow is enough to leave Normal.
>   - While emergency protection is active, emergency mode stops ordinary proposal execution for its set duration. The Emergency Execution Committee can then execute a scheduled proposal at once, and the end of emergency mode cancels every pending proposal. After an emergency reset the Reseal Manager stops working, and Voting directs the Agent through a timelock without the stETH holders' veto.
>   - If Dual Governance adopts a new Reseal Manager, Lido Lend controllers keep the old one, and new activations require it until a new `LidoLendMarketFactory` and activation factory are deployed.
>   - A Rage Quit or a resealed Withdrawal Queue can delay stETH redemption, so wstETH may trade below the accounting rate at which the WETH/wstETH oracle prices it. That oracle risk is described in [WETH / wstETH](markets/eth-steth.md).
> - **Mitigations:**
>   - A finite pause still ends on its own unless resealed.
>   - In a tie the Tiebreaker can resume a controller, after its own vote and execution delay.
>   - The Agent can grant the pause roles to a new Reseal Manager once proposals run again.

## Related specifications

- [Privileged Roles](roles.md): every role, its holder, and its impact class.
- [Market Controller Policy](market-controller.md): collateral activation, freeze, and pause.
- [Guardian Signals](guardian-signals.md): bans, latching, pruning, and the quorum frontier.
- [Settlement and Lender Exits](lender-settlement.md) and [Exit Books](exit-books.md): what the settlement and allowlist motions change.
