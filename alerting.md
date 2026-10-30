# Lido Lend: On-Chain Alerting Specification


## 0. Conventions

- Pseudocode uses `<contract>.<view>()` for `eth_call` and `event Foo(...)` for log subscriptions. `now` denotes `block.timestamp`. `H` denotes the alert's tracked block; `@H` means "read at block H"; `@H-1` is the parent block; `prev(H)` denotes the previous polling tick.
- **Baseline** = a persistent value the bot loads at boot from config. The canonical source is the deployment registry (`deployed/<run>/` in `lido-lend-markets`: `protocol.toml`, `markets/`, `guardians/`, `circuit-breakers/`) plus the role manifest per `docs/specs/roles.md`. On startup the bot MUST:
  - load previously persisted state,
  - fire the matching drift alert if observed chain state differs from the persisted baseline,
  - persist accepted changes as the new baseline only via a reviewed config update after a verified governance action, never automatically from chain state.
- **Message format.** Every message is self-contained: the reader triages without opening an explorer.

  ```
  <severity emoji> <ALERT-ID> · <market> · <short human title>
  <2 to 5 fact lines: who, how much, versus what limit, since when>
  Time: <window and its source>            (when the protocol defines a clock)
  Act: <verb + control> → <role that holds it>
  Not an attack if: <innocent cause + the check>   (mandatory for critical)
  Related: <alert IDs fired earlier in this incident, with age>
  tx <hash> · <subject link> · runbook <link>
  ```

  Emoji by severity: 🚨 critical, 🟠 high, 🔵 medium, 📊 info. Numbers in human units, next to the limit they crossed ("4,210 of cap 4,000").
- **Severity and noise budget.** critical = invariant broke or an emergency control fired; pages on-call 24/7; steady-state ≈ 0 per quarter. high = risk building or protection weakened; reviewed the same working day; ≤ 2 per week. medium = state change worth review in daily ops; ≤ 2 per day. info = no decision; collected into the daily digest (§14). There is no low: an alert with no decision is digest material. An alert that exceeds its budget in honest operation gets redesigned (threshold, hysteresis, aggregation), never muted.
- **Finality.** Bots read the newest block. Before any hard-to-undo action, re-check the condition at the latest block. All critical checks are view-call re-derivable, so a missed or reorged block costs nothing: re-run.
- The monitoring MUST be implemented as an isolated bot (not entangled with other protocol or governance bots).
---

## 1. Scope and Architecture

### 1.1 In scope (this bot, per deployment)

| Component | How many | Watched for |
| --- | --- | --- |
| `LidoLend` core (Morpho Blue fork) | 1 | all market action and admin events; positions; owner |
| `LidoLendMarketController` | 1 per market | activation buckets, freeze/pause, settlement queue, policy config |
| `LidoLendERC4626` vault | 1+ per market | share backing, fallback exit, deposit/exit limits |
| `GuardianSignals` | 1 per guardian group | flags, bans, heartbeats, quorum frontier |
| `RiskStewardDashboard` | 1 | steward set, tighten-only actions |
| `LidoLendOwner` | 1 | governance facade roles; holds core `owner` |
| `CircuitBreaker` | 1 | the only `PAUSER_ROLE` holder; own expiry heartbeat |
| Oracle adapters | 1 per market | `price()` |
| `IrmRouter` + `AdaptiveCurveIrm` | 1 each | routes, curve config, ownership |
| Exit books | optional | requests, fills, fees, allowlists, recovery |
| `Bundler3` + adapters (`EthereumGeneralAdapter1`, `LidoLendVaultAdapter`) | 1 + 2 | resting balances; grant targets (allowances, core authorizations); not proxied, no events |
| Every `OssifiableProxy` wrapping the above | many | admin, implementation, ossification |

### 1.2 Explicitly out of scope (this spec version)

- EasyTrack and the governance motion pipeline: EasyTrack has its own dedicated alerting. This bot does not subscribe to `MotionCreated`; runbooks direct the responder to that channel for motion checks.
- The broader wstETH/stETH token and Lido core protocol surface (covered by existing Lido monitoring).
- Off-chain infrastructure health (RPC, Grafana, Prometheus) and the bots' own liveness plumbing.

### 1.3 Per-market component map

For each market `M` in the registry the bot must, on boot, resolve and persist:

```text
M.id                                    bytes32 market id
core.idToMarketParams(M.id)             (loanToken, collateralToken, oracle, irm, lltv)   # immutable after creation
core → SetMarketController(M.id)        controller address
core → EnableSettlement(M.id)           settlement flag (bool, one-way)
controller.guardianSignals()            guardian registry for this market
registry → vault(s), exit book(s)       per market
controller config snapshot              CollateralActivationConfig + SettlementConfig + supply cap
instant-activation allowlist            from InstantActivationSet events
registry → periphery set                Bundler3 + the two adapters; immutables asserted at boot (§2.6)
registry → reference price sources      per market, independent of its oracle (O05, O06)
proxy admin + implementation            per OssifiableProxy (proxy__getAdmin / proxy__getImplementation)
```

A market with no controller binding is plain Morpho and gets core-level alerts only.

### 1.4 Governance topology (expected holders)

No addresses are pinned; holders are resolved from the registry and role manifest at boot. Expected layout:

| Contract | Surface | Expected holder |
| --- | --- | --- |
| every `OssifiableProxy` | proxy admin | Lido DAO Agent |
| `LidoLend` core | `owner` | `LidoLendOwner` facade |
| `LidoLendOwner` | `DEFAULT_ADMIN_ROLE` | Lido DAO |
| `LidoLendOwner` | `MARKET_CREATOR_ROLE`, `MARKET_MANAGER_ROLE`, `GUARDIAN_MANAGER_ROLE` | EVMScriptExecutor |
| `LidoLendOwner` | `FEE_MANAGER_ROLE` | Lido DAO Agent |
| controller | `DEFAULT_ADMIN_ROLE` | Lido DAO Agent |
| controller | `MANAGER_ROLE` | `LidoLendOwner` + `RiskStewardDashboard` |
| controller | `FREEZER_ROLE` | `RiskStewardDashboard` |
| controller | `UNFREEZER_ROLE` | `LidoLendOwner` |
| controller | `PAUSER_ROLE` | CircuitBreaker |
| controller | `RESUMER_ROLE` | **nobody** (deliberate; any grant → G05 first line) |
| `GuardianSignals` | `MANAGER_ROLE`, `ACCESS_RESTORER_ROLE` | `LidoLendOwner` |
| `GuardianSignals` | `ACCESS_LIMITER_ROLE` | **nobody** (deliberate; any grant → G05 first line) |
| `RiskStewardDashboard` | `STEWARD_ADMIN_ROLE` | EasyTrack executor |
| `RiskStewardDashboard` | per-market stewards | risk steward committee (via `MarketStewardSet`) |
| exit books | `DEFAULT_ADMIN_ROLE`, `FEE_MANAGER_ROLE`, `RECOVERER_ROLE` | Lido DAO (Agent) |
| exit books | `ALLOWLIST_MANAGER_ROLE` | EasyTrack executor + DAO Agent |
| `IrmRouter` / `AdaptiveCurveIrm` | owner / manager | DAO Agent / EVMScriptExecutor |

---

## 2. Constants the bot must keep

### 2.1 Role hashes

```text
DEFAULT_ADMIN_ROLE        = 0x0000000000000000000000000000000000000000000000000000000000000000

# LidoLendOwner
MARKET_CREATOR_ROLE       = 0xd3065a24ad9e7725d223007135762d2902038999e3e5829146654498a58d9795
FEE_MANAGER_ROLE          = 0x6c0757dc3e6b28b2580c03fd9e96c274acf4f99d91fbec9b418fa1d70604ff1c
MARKET_MANAGER_ROLE       = 0x959ec338079b71742207829b3534c23a2ddd8bcc180652a0ea6677af748b5fed
GUARDIAN_MANAGER_ROLE     = 0xb3afbb2c56b38273bac1b7b0b06fc410454e2570313eb67ef81dfaef813acd18

# LidoLendMarketController
MANAGER_ROLE              = 0x241ecf16d79d0f8dbfb92cbc07fe17840425976cf0667f022fe9877caa831b08
FREEZER_ROLE              = 0x92de27771f92d6942691d73358b3a4673e4880de8356f8f2cf452be87e02d363
UNFREEZER_ROLE            = 0x3e02eaefb22229c9fa4ecb927d4a3b0bd2d30b1af650a970c5a95ba1f96906ea
PAUSER_ROLE               = 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a
RESUMER_ROLE              = 0xf7f4a11bd0d206dbf09149f977ee978cf87879c93f7d8d7b725d222bdd3aa5e3

# GuardianSignals (MANAGER_ROLE hash shared with controller)
ACCESS_LIMITER_ROLE       = 0xfc5f5b5f0f3f8995740cf969e82c673b6edb5075d8813046f28c6058bdd58de0
ACCESS_RESTORER_ROLE      = 0x2185faf57ed59187a53d561a36691febce26676457b65b4553aa732fd2c9d195

# RiskStewardDashboard
STEWARD_ADMIN_ROLE        = 0x4aadd87f245821b0ca19440acc61321fad3b1dd387bc52b706900941926fbce8

# Exit books (FEE_MANAGER_ROLE / PAUSER_ROLE / RESUMER_ROLE hashes shared with the above)
ALLOWLIST_MANAGER_ROLE    = 0x8f951261ef278c1584c41b9b68518433e1baeac2a60d977f71ca9fe81511cc2f
RECOVERER_ROLE            = 0xb3e25b5404b87e5a838579cb5d7481d61ad96ee284d38ec1e97c07ba64e7f6fc
```

> The bot must derive these via `keccak256(<role-name>)` at boot and assert each matches the literal above. Any mismatch crashes the bot: every role-drift check depends on them.

### 2.2 Proxy surfaces

`OssifiableProxy` is ERC-1967 based and exposes views, so slot reads are a cross-check, not the primary source:

```text
proxy__getAdmin()          proxy admin (Lido DAO Agent expected)
proxy__getImplementation() implementation
proxy__getIsOssified()     true after ossification (admin renounced, upgrades impossible)

ADMIN_SLOT          = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
```

Read slots with `eth_getStorageAt`; values are right-aligned, strip the zero padding before comparing.

### 2.3 Protocol constants

```text
ORACLE_PRICE_SCALE                 = 1e36     # core price scale
VIRTUAL_SHARES / VIRTUAL_ASSETS    = 1e6 / 1  # core share-math offsets
MAX_BORROW_SHARE_RATE              = 1e7      # controller cap; check: totalBorrowShares + 1e6 > 1e7 * (totalBorrowAssets + 1)
MAX_FEE                            = 25%      # core protocol fee cap
MAX_SERVICE_FEE                    = 25%      # exit book service fee cap
MAX_PRIORITY_FEE                   = 10%      # exit book ramp cap
MAX_DELAY_DURATION                 = 7 days   # activation delay / lock duration cap
MAX_GUARDIANS_COUNT                = 32
MAX_SUSPECT_WINDOW                 = 30 days
DEFAULT_MAX_SETTLEMENT_ITERATIONS  = 150      # vault fallback-exit loop cap
PAUSE bounds (draft breaker config) = 5 to 60 days, initial 21 days; breaker heartbeat interval 365 days
```

### 2.4 Draft market parameters (ETH/wstETH, `script/config/markets/weth-wsteth.toml`)

Draft values, not decisions. LLTV is a governance parameter set at market creation and is deliberately not quoted here.

```text
minActivationDelay / maxActivationDelay = 600 s / 7200 s
maxDelayInflow                          = 10,000 wstETH
minActivationAmount                     = 10 wstETH
delayPerStrike                          = 7200 s
maxGuardiansQuorumDelay                 = 0        # frontier gate off in the draft
sliceFloorBps / ltvStepBps              = 100 / 100
fullCutBelowCollateral                  = 10 wstETH
guardians = [] , quorum = 1             # PLACEHOLDER: no committee yet; A- and W-plane alerts idle until one exists
```

### 2.5 Per-market monitoring thresholds

Filled per market at onboarding (OPS01). Draft column = ETH/wstETH example.

| Parameter | Used by | Guidance | Draft |
| --- | --- | --- | --- |
| `maxDownwardJumpBps` / `maxUpwardJumpBps` | O02 | 0 (any drop) / ≥ 10× largest honest step | 0 / 50 |
| `rateStaleWindow` | O03 | 1.5× upstream update period | 36 h |
| `feedHeartbeat + feedStaleMargin` | O04 | from feed docs | n/a |
| `depegToleranceBps / depegCriticalBps` | O05 | above normal wobble / pause territory | 100 / 300 |
| `depegConfirmWindow` | O05 | discount must hold this long | 30 m |
| `oracleDivergenceBps / divergenceConfirmWindow` | O06 | oracle vs reference gap | 200 / 30 m |
| `sourceDisagreeBps` | O05, O06 | cross-source sanity bound | 50 |
| `depegWatchWindow` | O05 fallback | behavioral correlation window | 6 h |
| `dustWaveCount / dustWaveWindow` | A01 | vs `minActivationAmount` | 20 / 24 h |
| `maturityLookahead / maturityWaveMin` | A03 | ≥ guardian reaction time / notable size | 6 h / 2% of supply or 500 wstETH |
| `flagWaveCount / flagWaveWindow` | A04 | scale to committee | 5 / 6 h |
| `liquidationWaveWindow` | S05 | short | 1 h |
| `sharePriceDropToleranceBps` | V02 | rounding only | 0 |
| `exitPressureWindow` | V03 | aggregation window | 4 h |
| `utilizationHighBps / utilizationHighWindow` | V04, O05 | above IRM target with margin | 9900 / 6 h |
| `maxFeeFillCount / maxFeeFillWindow` | V05 | small | 3 / 12 h |
| `pauseEndingOffsets` | E02 | before resume time | 48 h, 6 h |
| `breakerHeartbeatWarning` | E08 | ~10% of interval | 30 d |
| `frontierStallWindow` | W01 | 2–3× heartbeat period | 6 h |
| `guardianSilentWindow` | W02 | looser than frontier window | 24 h |
| `peripheryDustValue` | P01 | absorbs stETH 1–2 wei transfer residue | 0.001 ETH eq. |
| `peripheryNotableValue` | P01 → high | user-meaningful money | 1 ETH eq. |
| `approvalFanoutCount / approvalFanoutWindow` | P02 | distinct grantors to one unknown target | 3 / 24 h |
| `managerFanoutCount / managerFanoutWindow` | P03 → high | distinct accounts per unknown caller | 2 / 24 h |
| `notableAmount / notablePoolShareBps` | digest | ~1% of pool / share of supply | 100 WETH·wstETH / 500 |

### 2.6 Periphery boot assertions

The registry's periphery set is `bundler3` plus the two adapters in `src/adapters/`. Every wiring value is an immutable, so the bot asserts them once at boot:

```text
generalAdapter.BUNDLER3()        == bundler3
generalAdapter.MORPHO()          == core
generalAdapter.WRAPPED_NATIVE()  == WETH
generalAdapter.ST_ETH() / WST_ETH() == stETH / wstETH
vaultAdapter.BUNDLER3()          == bundler3
```

A mismatch is a wrong registry entry: refuse to start. The periphery contracts hold no roles and sit behind no proxy, so after boot there is no wiring drift to watch.

---

## 3. Threat model summary

| Class | Worst-case impact | Primary signal |
| --- | --- | --- |
| Tainted collateral borrows lender funds | lenders' loan tokens leave; market holds frozen-risk collateral | A02, A03 (anticipatory), A05 (invariant) |
| Policy layer failure (controller bug/bypass) | unlimited borrow or settlement outside policy | A05, A06, S02, S03, S04 |
| Lender loss / broken accounting | bad debt socialized; wrong share price | S01, V01, V02 |
| Oracle failure or compromise | all solvency math wrong at once; liquidation/settlement on bad price | O01, O02, O06; O03/O04 (early) |
| Market depeg (invisible to contracts) | collateral overpriced by design | O05 (reference price vs parity) |
| Governance/key compromise | any rule replaced via upgrade, owner, or role grant | G01–G05; G02 (anticipatory) |
| Risk config loosened | thinner guardian window, weaker gates | G06, G07, G08 |
| Exit degradation / lender run | withdrawals fail, exits cut borrowers | V03–V05; S01 blocks settlement |
| Defense layer unavailable | pause or ban powers expired, or the delay window unwatched | E07, E08, W01, W02, W03 |
| Silent reopening after incident | paused market resumes unfixed, no event | E02 (countdown), E03 |
| Periphery abuse | users' wallets drained via farmed grants or an unknown manager; funds left in adapters taken | P02 (anticipatory), P03; P01 |

---

## 4. Governance Plane (G)

### G01. Proxy implementation changed (`LL-PROXY-UPGRADED`)

- **Severity:** critical. **Cadence:** event-first + per-100-block storage/view poll (carousel over all proxies).
- **Scope:** every `OssifiableProxy` in the registry.
- **Rationale:** the proxy's logic was replaced; the new code is live from that block. Anything it does wrong is already happening.
- **Trigger logic:**

  ```text
  on event Upgraded(implementation) where log.address ∈ PROXIES:
      emit Finding(critical, "G01", ...)

  # per-100-block poll (catches event-less drift):
  for proxy in PROXIES:
      impl = proxy.proxy__getImplementation()@H  # cross-check IMPLEMENTATION_SLOT via eth_getStorageAt
      if impl != BASELINE[proxy].impl:
          emit Finding(critical, "G01", evidence={proxy, impl, baseline, txHash@last_change})
  ```

- **Evidence:** proxy, old/new implementation, code hash of the new implementation vs the reviewed build, tx hash.
- **False positive:** a reviewed motion or omnibus vote shipped the upgrade. Motions are watched by EasyTrack's own alerting; the responder checks that channel.
- **Runbook:** no matching motion → treat as takeover: request CircuitBreaker pause, escalate to governance and security, prepare public comms. Motion matches → verify the code hash against the reviewed build, then update the baseline via config PR.
- **Example message:**

  ```
  🚨 LL-PROXY-UPGRADED · protocol · controller implementation changed
  Upgraded on WETH/wstETH controller proxy: 0xImplA…31 → 0xImplB…97 at 15:40 UTC.
  Executed directly by the proxy admin (DAO Agent). New code is live from this block.
  Act: treat as potential takeover: request CircuitBreaker pause, escalate to governance and security → on-call.
  Not an attack if: a reviewed motion or omnibus vote matches. Check the EasyTrack alert channel and today's vote list: none touching Lend.
  Related: none.
  tx 0xaa…20 · runbook <link>
  ```

### G02. Proxy admin changed (`LL-PROXY-ADMIN-CHANGED`)

- **Severity:** critical. **Cadence:** event-first + per-100-block storage/view poll (same carousel as G01).
- **Scope:** every `OssifiableProxy` in the registry.
- **Rationale:** distinct from an upgrade: the contract's behavior has not changed yet, but every future upgrade and ossification of this proxy now needs the new key. Only the current admin can hand the admin back, so governance cannot reclaim it on its own. The expected admin for every proxy is the DAO Agent (§1.4). An unplanned change is the step before a hostile upgrade; the response window is before that upgrade lands.
- **Trigger logic:**

  ```text
  on event AdminChanged(previousAdmin, newAdmin) where log.address ∈ PROXIES:
      emit Finding(critical, "G02", ...)

  # per-100-block poll (catches event-less drift):
  for proxy in PROXIES:
      admin = proxy.proxy__getAdmin()@H          # cross-check ADMIN_SLOT via eth_getStorageAt
      if admin != BASELINE[proxy].admin:
          emit Finding(critical, "G02", evidence={proxy, admin, baseline, txHash@last_change})
  ```

- **Evidence:** proxy, old/new admin, tx hash.
- **False positive:** a reviewed custody change (motion or omnibus vote). Same check via the EasyTrack alert channel.
- **Runbook:** unplanned → treat as key compromise: request CircuitBreaker pause, escalate, watch the proxy for the follow-up `Upgraded` (G01), and plan migration off the proxy if the admin is not recovered. Planned → update the baseline via config PR.
- **Example message:**

  ```
  🚨 LL-PROXY-ADMIN-CHANGED · protocol · vault proxy admin left the DAO Agent
  AdminChanged on WETH/wstETH vault proxy: DAO Agent → 0x4b4b…99 (unknown) at 02:50 UTC.
  Behavior unchanged so far, but every future upgrade of this proxy needs the new key, and governance cannot take the admin back.
  Act: request CircuitBreaker pause; escalate as key compromise; watch for a follow-up upgrade → on-call.
  Not an attack if: a reviewed custody change matches. Check the EasyTrack alert channel and today's vote list: none.
  Related: none.
  tx 0x9e…41 · runbook <link>
  ```

### G03. Proxy ossified (`LL-PROXY-OSSIFIED`)

- **Severity:** critical. **Cadence:** event-first.
- **Scope:** every `OssifiableProxy`.
- **Rationale:** ossification is forever and kills the upgrade path the incident plan (ADR 029) relies on.
- **Trigger logic:**

  ```text
  on event ProxyOssified() where log.address ∈ PROXIES:
      emit Finding(critical, "G03", evidence={proxy, txHash,
          isOssified=proxy.proxy__getIsOssified()@H})
  ```

- **False positive:** a governance decision that planned ossification at this stage (none is on record for launch).
- **Runbook:** respond as takeover (pause, escalate); re-plan every fix that assumed upgrading this contract.
- **Example message:**

  ```
  🚨 LL-PROXY-OSSIFIED · protocol · oracle proxy ossified
  ProxyOssified() on the WETH/wstETH oracle proxy at block 21,460,318. Upgrades are now impossible, forever.
  No governance decision on record plans ossification at this stage.
  Act: respond as takeover (pause, escalate); re-plan every fix that assumed upgrading this contract → on-call.
  Not an attack if: a reviewed ossification decision exists. None on record.
  tx 0x1f…6b · runbook <link>
  ```

### G04. Core owner changed (`LL-CORE-OWNER-CHANGED`)

- **Severity:** critical. **Cadence:** event-first + per-100-block `owner()` poll.
- **Scope:** `LidoLend` core.
- **Rationale:** the owner gates market creation and routes all controller/registry governance. A wrong owner replaces the whole governance layout in one call.
- **Trigger logic:**

  ```text
  on event SetOwner(newOwner) at CORE, or owner()@H != BASELINE.ownerFacade:
      emit Finding(critical, "G04", evidence={newOwner, baseline, txHash,
          facadeRoleEventsInSameTx})
  ```

- **False positive:** a planned facade migration via `transferLidoLendOwnership`, with facade role events in the same transaction.
- **Runbook:** pause everything pausable; emergency escalation.
- **Example message:**

  ```
  🚨 LL-CORE-OWNER-CHANGED · protocol · core owner is no longer the governance facade
  SetOwner: 0xFacade…01 → 0x9d9d…77 (unknown address) at 03:12 UTC.
  Every governance path to every market now routes through an unknown key.
  Act: pause everything pausable; emergency escalation → on-call + breaker committee.
  Not an attack if: planned facade migration (transferLidoLendOwnership + role events same tx). Tx has neither.
  tx 0xb2…c8 · runbook <link>
  ```

### G05. Role drift on the stack (`LL-ROLE-DRIFT`)

- **Severity:** critical. **Cadence:** event-first + per-100-block full diff via enumerable role members.
- **Scope:** controllers, guardian registries, dashboard, `LidoLendOwner`, exit books.
- **Trigger logic:**

  ```text
  on event RoleGranted(role, account, sender) OR RoleRevoked(...) OR RoleAdminChanged(...)
    where log.address ∈ ACL_CONTRACTS:
      observed = getRoleMembers(log.address, role)@H
      if set(observed) != set(ACL_BASELINE[log.address][role]):
          headline = role ∈ {RESUMER_ROLE, ACCESS_LIMITER_ROLE, PAUSER_ROLE, DEFAULT_ADMIN_ROLE}
          emit Finding(critical, "G05", evidence={contract, role, delta, observed, baseline,
              txHash, headline})

  # per-100-block tick: recompute the full (contract, role) diff — catches same-tx
  # grant → use → revoke sequences that event-driven diffs miss.
  ```

- **Evidence:** contract, role name + hash, accounts added/removed, sender.
- **False positive:** a matching reviewed motion; the deliberately-unheld roles (`RESUMER_ROLE`, `ACCESS_LIMITER_ROLE`) have no innocent grant until a written policy exists.
- **Runbook:** no motion → assume stolen admin key: list what the new holder can do; pause if that list touches funds; revoke via DAO Agent.
- **Example message:**

  ```
  🚨 LL-ROLE-DRIFT · protocol · RESUMER_ROLE granted (held by nobody at launch, by design)
  RoleGranted on WETH/wstETH controller: RESUMER_ROLE → 0x5e5e…c1 at 22:47 UTC.
  Holder can now end any pause early: the emergency stop is no longer guaranteed to hold.
  No motion on record; check the EasyTrack alert channel.
  Act: verify with governance; if unplanned, treat as key compromise: pause, revoke via DAO Agent → on-call.
  Not an attack if: the pre-agreed incident-response grant (see resumers policy). Policy shows no grant scheduled.
  tx 0x6e…f4 · runbook <link>
  ```

### G06. Market config loosened (`LL-CONFIG-LOOSENED`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every controller.
- **Trigger logic:**

  ```text
  LOOSER = {
    minActivationDelay: smaller, maxActivationDelay: smaller,
    maxDelayInflow: larger, delayPerStrike: smaller, delayPerSuspect: smaller,
    activatingLockAmount: smaller, activatingLockDuration: smaller,
    minActivationAmount: smaller,
    maxGuardiansQuorumDelay: smaller or 0,
    supplyCap: larger or removed,
    sliceFloorBps | sliceFloorAssets | ltvStepBps | fullCutBelowCollateral: ANY change
  }

  on event CollateralActivationConfigSet(config) OR SettlementConfigSet(config)
       OR SupplyCapSet(cap, account) where log.address ∈ CONTROLLERS:
      delta = diff(config@H, SNAPSHOT[log.address])
      if any field moved per LOOSER:
          emit Finding(high, "G06", evidence={market, delta})
      else: route to digest (tightening / neutral)
      SNAPSHOT update only after review
  ```

- **False positive:** none; a matching motion makes the change expected, but it still needs the same-day review (config risk went up).
- **Runbook:** verify against the reviewed motion in the EasyTrack alert channel; if no motion, the steward re-tightens via dashboard while the path is investigated; recompute §2.5 thresholds that use the changed fields.
- **Example message:**

  ```
  🟠 LL-CONFIG-LOOSENED · WETH/wstETH · activation delays halved
  CollateralActivationConfigSet at 14:06 UTC: minDelay 600→300 s, maxDelay 7200→3600 s. Other fields unchanged.
  Guardian reaction window is now half.
  Act: match against the reviewed motion in the EasyTrack alert channel; confirm the guardian committee was told; recompute worksheet thresholds that use the delays → protocol team.
  Related: none.
  tx 0x2b…91 · runbook <link>
  ```

### G07. Instant activation granted (`LL-INSTANT-ACTIVATION-GRANTED`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every controller.
- **Rationale:** an instant-activation caller skips the delay entirely; the main safeguard does not apply to flows through it.
- **Trigger logic:**

  ```text
  on event InstantActivationSet(caller, enabled) where log.address ∈ CONTROLLERS:
      if enabled:
          emit Finding(high, "G07", evidence={market, caller,
              callerCodeHash=keccak(getCode(caller)@H), approvedHash})
      else:
          route: dashboard revoke → E06; other revokes → digest
  ```

- **Runbook:** compare the caller's code hash with the audited build; wrong grant → steward `revokeInstantActivation` is the fast fix.
- **Example message:**

  ```
  🟠 LL-INSTANT-ACTIVATION-GRANTED · WETH/wstETH · 0xR0ut…3r skips the activation delay
  InstantActivationSet(0xR0ut…3r, true) at 10:31 UTC by the EVMScriptExecutor.
  Code hash matches audited LoopingRouter v1.2 build ✔.
  Act: verify the motion in the EasyTrack alert channel; add the router to the watched-callers list → protocol team.
  Not an attack if: a reviewed motion matches and the code hash is the audited one.
  tx 0x44…d2 · runbook <link>
  ```

### G08. Rate model changed (`LL-IRM-CHANGED`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** `IrmRouter`, `AdaptiveCurveIrm`.
- **Rationale:** a market's stored `irm` never changes; the real model changes through the router route or curve config, which is easy to miss.
- **Trigger logic:**

  ```text
  on event MarketIrmSet(id, irm) OR IrmConfigApplied(marketId, config)
       OR OwnershipTransferred(prev, new) OR ManagerSet(manager)
    where log.address ∈ {IRM_ROUTER, ADAPTIVE_CURVE_IRM}:
      if event is IrmConfigApplied during onboarding of a not-yet-covered market: skip
      emit Finding(high, "G08", evidence={event, args})
  ```

- **Runbook:** verify the motion in the EasyTrack alert channel; watch `BorrowRateUpdate` and `AccrueInterest` for abnormal rates afterward.
- **Example message:**

  ```
  🟠 LL-IRM-CHANGED · WETH/wstETH · curve config re-applied
  IrmConfigApplied at 09:15 UTC: target utilization 90% → 85%, curve steepness unchanged.
  Enacted by the EVMScriptExecutor. Borrow rates will shift down at the margin.
  Act: confirm risk team expected this; watch next BorrowRateUpdate ticks → protocol team.
  tx 0x9a…07 · runbook <link>
  ```

### G09. Fees changed (`LL-FEE-CHANGED`)

- **Severity:** medium. **Cadence:** event-first.
- **Scope:** core; exit books.
- **Trigger logic:**

  ```text
  on event SetFee(id, newFee) OR SetFeeRecipient(newFeeRecipient) at CORE
       OR ServiceFeeSet(feeRecipient, serviceFee) at EXIT_BOOKS:
      emit Finding(medium, "G09", evidence={source, old, new, caps={MAX_FEE, MAX_SERVICE_FEE}})
  ```

- **Runbook:** verify the governance action; update published APY expectations.
- **Example message:**

  ```
  🔵 LL-FEE-CHANGED · WETH/wstETH · protocol fee 0% → 5%
  SetFee at 11:00 UTC by the EVMScriptExecutor. Lender APY drops ~0.2 pp at current rates.
  Act: update published APY expectations → protocol team.
  tx 0x51…33
  ```

---

## 5. Pricing Plane (O)

### O01. Oracle broken (`LL-ORACLE-BROKEN`)

- **Severity:** critical. **Cadence:** every block.
- **Scope:** every market's oracle adapter.
- **Rationale:** every borrow check, liquidation, and settlement prices collateral through this one call.
- **Trigger logic:**

  ```text
  for M in MARKETS:
      p = staticcall M.oracle.price()@H         # catch reverts
      if reverted OR p == 0:
          emit Finding(critical, "O01", evidence={market, revertReason | 0, sinceBlock})
      re-arm on first successful non-zero read
  # composed adapters: also match known failure reverts (InvalidNavPrice, InvalidStablePrice)
  ```

- **False positive:** an upstream rate-source upgrade in progress (check Lido core announcements).
- **Runbook:** request CircuitBreaker pause. **Freeze is the wrong control:** liquidation and settlement stay open under freeze and would run on the broken price.
- **Example message:**

  ```
  🚨 LL-ORACLE-BROKEN · WETH/wstETH · oracle.price() reverts
  price() reverted 4 blocks in a row since 21,455,100 (StalePrice() from the rate source).
  Borrow checks, liquidations, and settlements are all pricing through this call.
  Act: request CircuitBreaker pause → breaker committee. Freeze is NOT enough (liquidation/settlement stay open).
  Not an attack if: upstream rate-source upgrade in progress. Check Lido core announcements: none.
  oracle <link> · runbook <link>
  ```

### O02. Oracle price jump (`LL-ORACLE-PRICE-JUMP`)

- **Severity:** critical. **Cadence:** every block.
- **Scope:** every market's oracle adapter.
- **Rationale:** the wstETH accounting rate steps ~1 bps once a day and falls only on mass slashing. Any move outside the bounds means slashing is real or the rate source is compromised. This is the "Detect" step of ADR 029.
- **Trigger logic:**

  ```text
  delta_bps = (price@H - price@H-1) * 10_000 / price@H-1
  if delta_bps < -maxDownwardJumpBps OR delta_bps > maxUpwardJumpBps:
      emit Finding(critical, "O02", evidence={market, price@H-1, price@H, delta_bps, bounds})
  # value-bearing: may fire once per block while the move continues
  ```

- **False positive:** a catch-up rebase after missed daily reports (a few bps up at most, far below the 50 bps draft bound); a confirmed negative rebase after real mass slashing (the pause is still the right response, skip only the security escalation).
- **Runbook:** request CircuitBreaker pause first; then find the cause: a rebase report, a rate-source upgrade, or a hack. The fix ships as an upgrade before resume.
- **Example message:**

  ```
  🚨 LL-ORACLE-PRICE-JUMP · WETH/wstETH · rate dropped 0.8% in one block
  price(): 1.1842e36 → 1.1747e36 at block 21,456,001 (−80 bps; bound: any drop).
  An accounting rate falls only on mass slashing. Either slashing is real or the rate source is compromised.
  Act: request CircuitBreaker pause NOW → breaker committee. Then check Lido oracle reports for a negative rebase.
  Not an attack if: confirmed negative rebase (pause still correct; skip the security escalation).
  Related: none.
  oracle <link> · runbook <link>
  ```

### O03. Accounting rate stagnant (`LL-ORACLE-STAGNANT`)

- **Severity:** high. **Cadence:** every 12 blocks.
- **Scope:** accounting-rate oracles.
- **Trigger logic:**

  ```text
  if price()@H == price observed for > rateStaleWindow:   # draft 36 h; the rate steps daily
      emit Finding(high, "O03", evidence={market, price, unchangedSince})
  ```

- **Rationale:** a frozen rate keeps stale collateral values and blinds O02.
- **Runbook:** check the Lido AccountingOracle report pipeline; escalate if upstream reports an incident.
- **Example message:**

  ```
  🟠 LL-ORACLE-STAGNANT · WETH/wstETH · rate unchanged for 38 h
  price() = 1.1842e36 since 09:00 UTC yesterday. Expected: one ~1 bps step per daily rebase.
  While frozen, collateral values are stale and jump detection is blind.
  Act: check Lido AccountingOracle report status → protocol team.
  Not an attack if: known oracle-committee delay. Check the DAO ops channel.
  runbook <link>
  ```

### O04. Push feed stale (`LL-ORACLE-FEED-STALE`)

- **Severity:** high. **Cadence:** every 12 blocks.
- **Scope:** composed adapters that read push feeds (the USDY design). Not applicable to ETH/wstETH.
- **Rationale:** the adapter skips staleness checks on purpose (do not brick the market on a short feed hiccup), so monitoring owns feed staleness.
- **Trigger logic:**

  ```text
  for feed in COMPOSED_FEEDS[M]:
      age = now - feed.latestRoundData().updatedAt@H
      if age > feedHeartbeat + feedStaleMargin:
          emit Finding(high, "O04", evidence={market, feed, age, heartbeat})
  ```

- **Runbook:** contact the feed operator; a long-stale feed in a moving market justifies steward tightening or a pause discussion.
- **Example message:**

  ```
  🟠 LL-ORACLE-FEED-STALE · USDY/USDC · price feed 3.2 h past heartbeat
  USDC/USD feed last update 4.2 h ago (heartbeat 1 h + margin 15 m). Adapter keeps serving the old price by design.
  Act: contact feed operator; if the market moves meanwhile, raise steward tightening → protocol team.
  feed <link> · runbook <link>
  ```

### O05. stETH trades below parity (`LL-STETH-DEPEG`)

- **Severity:** high; critical at `depegCriticalBps`. **Cadence:** poll every 12 blocks.
- **Scope:** every market whose oracle assumes stETH/ETH parity (the accounting-rate design).
- **Rationale:** the oracle prices wstETH by the accounting rate and assumes 1 stETH = 1 ETH. A market discount on stETH is invisible to every contract: the market overprices wstETH, deposits and borrows against it become profitable, and settlements hand exiting lenders collateral worth less than its accounting value. Independent sources measure the discount directly; the tolerance margin keeps normal wobble silent. Independent means sharing nothing with any market oracle: the market oracles read Chainlink feeds, so Chainlink cannot serve as a reference source. The behavioral dials from earlier drafts stay as corroboration and as a fallback when the sources are down.
- **Trigger logic:**

  ```text
  # STETH_ETH_SOURCES: at least two on-chain sources sharing nothing with any market
  # oracle. Market oracles read Chainlink feeds, so Chainlink is excluded here.
  # Draft: Curve stETH/ETH pool EMA + Uniswap v3 wstETH/WETH TWAP; Chronicle or Redstone as a third.
  # (wstETH venues divide by the accounting rate to get stETH/ETH; O06 guards the rate itself)
  prices = [read(s)@H for s in STETH_ETH_SOURCES if fresh(s)]
  if prices == []:
      run behavioral fallback below; emit Finding(medium, "O05", "reference sources down")
  elif spread(prices) > sourceDisagreeBps:
      emit Finding(medium, "O05", "sources disagree — check the sources, not the peg")
  else:
      discount = 1 − median(prices)         # stETH below ETH is the dangerous side; premium → digest
      if discount ≥ depegToleranceBps sustained for depegConfirmWindow:
          emit Finding(high, "O05", evidence={per-source prices, discount, trend,
              inflow/utilization/exit dials})
      if discount ≥ depegCriticalBps: escalate to critical

  # behavioral fallback (sources down) — within depegWatchWindow, ≥ 2 of:
  #   inflow ≥ 50% of ceiling and rising · utilization ≥ utilizationHighBps
  #   exit-book fill at endRate or settle-leg FallbackExit
  ```

- **False positive:** a short dislocation that reverts inside the confirm window; a single bad source (the cross-source check catches it before the peg is blamed).
- **Runbook:** confirm depth and trend on a venue outside the source set; a confirmed, deepening discount escalates to the CircuitBreaker pause per ADR 029. A freeze is not enough: liquidation and settlement keep running on the accounting rate. Clock: the activation delay (10 min to 2 h) before the newest inflow can borrow.
- **Example message:**

  ```
  🟠 LL-STETH-DEPEG · WETH/wstETH · stETH trading 1.8% below ETH (tolerance 1%)
  Curve EMA stETH/ETH 0.9820 · Uniswap TWAP 0.9815 (agree within 5 bps) · discount held 45 m, widening.
  The market oracle still prices wstETH at the accounting rate: borrows and settlements ignore the discount.
  Market reaction: inflow 7,900/10,000 wstETH and rising · utilization 99.2% · first settle-leg exit 13:10 UTC.
  Time: newest inflow can borrow in 10 m to 2 h (activation delay).
  Act: confirm depth and trend; if it deepens, request the CircuitBreaker pause per ADR-029 (freeze is not enough) → risk steward + on-call.
  Not an attack if: a brief dislocation; firing needs 1%+ held 30 m on two agreeing sources.
  Related: LL-UTILIZATION-HIGH 2 h ago, LL-EXITBOOK-MAX-FEE 3 h ago.
  sources <link> · runbook <link>
  ```

### O06. Oracle diverges from the reference price (`LL-ORACLE-DIVERGENCE`)

- **Severity:** high. **Cadence:** poll every 12 blocks.
- **Scope:** every market with a configured reference price.
- **Rationale:** O01 catches a dead oracle, O02 catches jumps, O03 catches stagnation; an oracle that is wrong *smoothly* passes all three. The reference is built from the same independent sources, reading the collateral's own market price (for ETH/wstETH: direct DEX wstETH/ETH prices; never the accounting rate, never Chainlink). A sustained gap means the protocol prices collateral away from the market, whichever side is broken. If the reference shared a feed with the oracle, a fault in that feed would move both sides together and hide itself; that is why the sources must not overlap.
- **Trigger logic:**

  ```text
  ref = median([read(s)@H for s in REF_PRICE_SOURCES[market] if fresh(s)])
  if spread(sources) > sourceDisagreeBps: emit Finding(medium, "O06", "sources disagree"); skip
  gap = |oracle.price()@H / ORACLE_PRICE_SCALE − ref| / ref
  if gap ≥ oracleDivergenceBps sustained for divergenceConfirmWindow:
      emit Finding(high, "O06", evidence={oraclePrice, ref, per-source prices, gap, O05 state})
  ```

- **False positive:** a fast market move the confirm window has not caught up with (re-check both sides at the latest block). During a genuine depeg the gap is expected: O05 is active and both alerts join one story.
- **Runbook:** decide which side is wrong. O05 active → the market moved: follow the depeg path. O05 quiet → the oracle is suspect: compare the adapter output against `getStETHByWstETH` read directly, check the oracle proxy for upgrades (G01), and escalate for the CircuitBreaker pause if the gap holds or grows.
- **Example message:**

  ```
  🟠 LL-ORACLE-DIVERGENCE · WETH/wstETH · oracle 2.4% above the market reference
  oracle.price() 1.1842e36 · reference 1.1558e36 (DEX wstETH/ETH, 2 sources agree within 8 bps) · gap 2.4%, held 35 m.
  LL-STETH-DEPEG is quiet (stETH/ETH at parity), so the gap points at the oracle side.
  Every borrow and settlement during the gap uses the oracle's price, not the market's.
  Act: compare adapter output against getStETHByWstETH directly; check the oracle proxy for upgrades; escalate for pause if the gap holds → on-call.
  Not an attack if: a fast market move inside the confirm window; re-check at the latest block.
  Related: none.
  sources <link> · runbook <link>
  ```

---

## 6. Activation Plane (A)

The staged attack the delay exists for: (1) collateral arrives and the throttle climbs, (2) `unlockTime` approaches, (3) the lot matures, (4) the borrow. A01–A04 use the window; A05 and A06 fire only if the contracts failed to enforce the policy.

### A01. Dust-deposit wave (`LL-DUST-WAVE`)

- **Severity:** medium. **Cadence:** event-first, aggregated.
- **Scope:** every controller.
- **Trigger logic:**

  ```text
  on event CollateralDusted(borrower, amount, position):
      window.add(borrower)
  if distinct(window, dustWaveWindow) ≥ dustWaveCount:
      emit Finding(medium, "A01", evidence={market, count, totalAmount, addressList})
      re-arm after a quiet dustWaveWindow
  ```

- **Rationale:** the known spam pattern (ADR 014): many deposits below `minActivationAmount`, aimed at gates and monitors. Dust can never activate or borrow.
- **Runbook:** review the address list for links to known clusters → guardian committee.
- **Example message:**

  ```
  🔵 LL-DUST-WAVE · WETH/wstETH · 27 accounts made dust deposits in 6 h
  27 fresh addresses deposited 0.1–9.9 wstETH each (total 41 wstETH), all below the 10 wstETH activation floor.
  Dust cannot activate or borrow. Pattern matches ADR-014 spam.
  Act: review the address list for links to known clusters → guardian committee.
  Related: none.
  addresses <link> · runbook <link>
  ```

### A02. Inflow throttle saturated (`LL-INFLOW-SATURATED`)

- **Severity:** high. **Cadence:** every 12 blocks.
- **Scope:** every controller.
- **Trigger logic:**

  ```text
  if controller.currentInflow()@H ≥ maxDelayInflow:      # delays held at maxActivationDelay
      emit Finding(high, "A02", evidence={market, inflow, ceiling,
          depositorBreakdown(ledger, window), earliestUnlockInWave})
  # value-bearing: re-arm when inflow decays below 50% of the ceiling
  ```

- **Rationale:** real growth or an attacker pre-placing collateral. The clock is at least `maxActivationDelay` before the earliest of the wave matures.
- **Runbook:** guardian committee reviews depositors and lot sizes now; flags add `delayPerStrike` each; steward can raise delays via dashboard.
- **Example message:**

  ```
  🟠 LL-INFLOW-SATURATED · WETH/wstETH · inflow throttle at ceiling, delays held at the 2 h maximum
  Decayed inflow reached 10,000 wstETH (ceiling). 14 depositors in the last 3 h; largest 4,000 wstETH by 0x7a3f…9e12 (fresh address, funded via 2 hops from an OFAC-flagged bridge).
  Earliest unlock in this wave: 15:42 UTC (1 h 51 m from now).
  Time: ~1 h 51 m until the first lot can borrow.
  Act: review depositor list; flag suspects (each strike adds 2 h) → guardian committee.
  Not an attack if: known integrator addresses dominate the list. Check funding sources.
  Related: LL-DUST-WAVE 4 h ago.
  depositors <link> · runbook <link>
  ```

### A03. Large collateral matures soon (`LL-MATURITY-WAVE`)

- **Severity:** high. **Cadence:** every 12 blocks over the event ledger.
- **Scope:** every controller.
- **Rationale:** the last stage where flags still add delay; after maturity only a ban or a freeze blocks the borrow.
- **Trigger logic:**

  ```text
  # ledger-derived, no borrower polling:
  # base unlock = position.activatingStart + position.activatingDelay   (from the newest activation event)
  # + strikes(borrower) * delayPerStrike                                 (from Flagged events)
  # + suspect surcharge where an active suspect snapshot applies
  # where maxGuardiansQuorumDelay > 0: effectiveUnlock = max(unlock, frontier catch-up)

  wave = [p for p in ledger.activating if p.effectiveUnlock ≤ now + maturityLookahead]
  if sum(wave.activating) ≥ maturityWaveMin OR any single p ≥ maturityWaveMin:
      confirm positions named in the message with one positionOf(borrower) read each
      emit Finding(high, "A03", evidence={market, positions(borrower, amount, unlock, flags),
          sumVsSupply, borrowableAtLltv, freeLiquidity})
  # one message per wave; re-fire only if the set grows ≥ 25%
  ```

- **Runbook:** guardian committee reviews and flags now; after unlock only ban or freeze helps.
- **Example message:**

  ```
  🟠 LL-MATURITY-WAVE · WETH/wstETH · 6,200 wstETH becomes borrowable within 6 h
  3 positions mature soon: 4,000 wstETH (0x7a3f…9e12, unlock 15:42 UTC, 0 flags),
  1,400 wstETH (0x22c1…07dd, 16:05), 800 wstETH (0x90ab…11f2, 19:30).
  Together = 31% of market supply. At the market LLTV they can borrow up to 5,270 WETH; free liquidity is 5,900 WETH.
  Time: 1 h 48 m until the first unlock.
  Act: review and flag now; after unlock only ban/freeze help → guardian committee.
  Not an attack if: addresses belong to known entities. 0x7a3f…9e12 is 4 days old: verify.
  Related: LL-INFLOW-SATURATED 3 h ago.
  positions <link> · runbook <link>
  ```

### A04. One flag from a ban (`LL-STRIKES-NEAR-QUORUM`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every guardian registry.
- **Trigger logic:**

  ```text
  on event Flagged(marketId, account, guardian, actor, strikes):
      if strikes == getQuorum()@H - 1:
          emit Finding(high, "A04", evidence={market, account, strikes, quorum, position(ledger)})
      window.add(account)
  if distinct(window, flagWaveWindow) ≥ flagWaveCount:      # wave form, aggregated
      emit Finding(high, "A04.wave", evidence={accounts, window})
  # once per account per day
  ```

- **Rationale:** one more flag latches a ban, and bans are undone only by governance. The alert is committee coordination, not accusation.
- **Runbook:** confirm with the remaining guardians; decide before the account's unlock.
- **Example message:**

  ```
  🟠 LL-STRIKES-NEAR-QUORUM · WETH/wstETH · 0x7a3f…9e12 is 1 flag from a ban
  Strikes: 2 of quorum 3 (guardians 0xAA…01, 0xBB…02; actors = their delegates).
  Position: 4,000 wstETH activating, unlock 15:42 UTC, debt 0.
  A third flag latches a ban: borrowing blocked, maturation stops, exit stays open. Undo needs a governance motion.
  Act: confirm with the remaining guardians; decide before unlock → guardian committee.
  Related: LL-MATURITY-WAVE 40 m ago.
  account <link> · runbook <link>
  ```

### A05. Borrow bypassed the policy gates (`LL-BORROW-POLICY-BYPASS`)

- **Severity:** critical. **Cadence:** event-first (every `Borrow` / `WithdrawCollateral`).
- **Scope:** core events + controller and guardian views for the named borrower.
- **Rationale:** the controller must enforce: only `active` collateral backs a borrow; banned accounts cannot borrow; nothing moves while frozen or paused. One violating borrow means the policy layer failed and lender funds are leaving.
- **Trigger logic:**

  ```text
  on event Borrow(id, caller, onBehalf, receiver, assets, shares)
       or WithdrawCollateral(id, caller, onBehalf, receiver, assets):
      if event is Borrow:                          # ban gates borrowing only
          for a in {caller, onBehalf, receiver}:
              if guardians.isBanned(id, a)@H: emit Finding(critical, "A05.ban", ...)
      p = controller.positionOf(onBehalf)@H        # single-borrower read, event-scoped
      if p.debtAssets == 0: return
      capCollateral = p.active if p.active ≥ minActivationAmount else 0
      capacity = capCollateral * oracle.price()@H / 1e36 * lltv / 1e18
      if p.debtAssets > capacity + 1 wei
         OR controller.isFrozen()@H OR controller.isPaused()@H:
          emit Finding(critical, "A05", evidence={market, onBehalf, txHash, p, capacity})
  ```

- **False positive:** `isFrozen`/`isPaused` read end-of-block state; a freeze or pause landing after the borrow in the same block makes a legal borrow look frozen. Check transaction order inside the block before paging on those two branches. The ban and capacity branches have no innocent cause.
- **Runbook:** request the CircuitBreaker pause immediately. Freeze is not enough: it relies on the same controller whose check just failed, and it leaves settlement and liquidation open. Report the account to the guardians; save the position data.
- **Example message:**

  ```
  🚨 LL-BORROW-POLICY-BYPASS · WETH/wstETH · borrow against non-active collateral
  0x7a3f…9e12 borrowed 3,900 WETH at block 21,443,207 (14:32 UTC).
  Re-derived position: active 0, activating 4,000 wstETH (unlock in 1 h 10 m), debt 3,900 WETH > capacity 0.
  The controller must reject this call. Its check failed or was bypassed.
  Act: request CircuitBreaker pause NOW → breaker committee. Freeze is not enough.
  Not an attack if: (capacity branch) nothing known. Verified at latest block: still true.
  Related: LL-MATURITY-WAVE 2 h ago, LL-INFLOW-SATURATED 5 h ago.
  tx 0x5c…88 · position <link> · runbook <link>
  ```

### A06. Collateral matured while frozen (`LL-FROZEN-MATURATION`)

- **Severity:** critical. **Cadence:** event-first.
- **Scope:** every controller.
- **Trigger logic:**

  ```text
  on event CollateralActivated(borrower, amount, position) where controller.isFrozen()@H:
      if no FrozenSet(false) earlier in the same block:
          emit Finding(critical, "A06", evidence={market, borrower, amount, frozenSince, txHash})
  ```

- **Rationale:** a freeze must halt maturation; a lot flipping to `active` under freeze means the freeze mechanism is broken.
- **Runbook:** request CircuitBreaker pause. The freeze mechanism itself is broken, so it cannot be the response.
- **Example message:**

  ```
  🚨 LL-FROZEN-MATURATION · WETH/wstETH · collateral matured during a freeze
  CollateralActivated: 1,400 wstETH for 0x22c1…07dd at block 21,444,981.
  isFrozen() == true at this block (frozen since 13:05 UTC by steward via dashboard).
  Freeze must halt maturation. Controller bug or bypass.
  Act: request CircuitBreaker pause → breaker committee.
  Not an attack if: unfreeze executed earlier in the same block. Checked: no FrozenSet(false) in block.
  tx 0x91…c3 · runbook <link>
  ```

---

## 7. Settlement & Solvency Plane (S)

### S01. Bad debt at the queue root (`LL-MARKET-BAD-DEBT`)

- **Severity:** critical. **Cadence:** every block.
- **Scope:** every controller.
- **Rationale:** the riskiest borrower owes more than their collateral is worth: the market carries a loss AND every settlement call now reverts (`SettlementBadDebt`), closing the settlement exit path.
- **Trigger logic:**

  ```text
  if controller.hasBadDebt()@H AND NOT hasBadDebt()@prev(H):
      root = controller.nextSettlementBorrower(0)@H
      emit Finding(critical, "S01", evidence={market, root.borrower, debt, collateral,
          price@H, ltv})
  # re-arm on flip back to false; a one-block flip resolved by a liquidation in the
  # next block downgrades to medium with the Liquidate receipt attached
  ```

- **False positive:** a brief oracle-step overshoot right after a rebase (check O02 history).
- **Runbook:** confirm at the latest block; expect keeper liquidation; if it persists > 30 m, ask the steward to freeze while governance prepares a response. Settlement stays blocked either way.
- **Example message:**

  ```
  🚨 LL-MARKET-BAD-DEBT · WETH/wstETH · queue root is underwater, settlement blocked
  hasBadDebt() flipped true at block 21,450,002.
  Root 0x44de…a9c0: debt 912 WETH vs collateral 1,050 wstETH ≈ 897 WETH at current rate (LTV 101.7%).
  All settle calls now revert: the settlement exit path is closed.
  Act: confirm at latest block; expect keeper liquidation; if it persists >30 m, ask steward to freeze → on-call.
  Not an attack if: brief oracle-step overshoot right after a rebase; check O02 history (none in 24 h).
  Related: LL-EXIT-PRESSURE 6 h ago.
  position <link> · runbook <link>
  ```

### S02. Settlement cut outside policy (`LL-SETTLE-POLICY-BREACH`)

- **Severity:** critical. **Cadence:** event-first (every `Settle`).
- **Scope:** core `Settle` events + controller pre-state.
- **Rationale:** core `settle` has no health check of its own; the controller's math is the only bound on how hard a borrower can be cut.
- **Trigger logic:**

  ```text
  on event Settle(id, caller, onBehalf, borrower, receiver,
                  supplySharesBurned, borrowAssetsCanceled, borrowSharesCanceled, seizedAssets):
      if id ∉ SETTLEMENT_ENABLED:                       # no EnableSettlement(id) ever
          emit Finding(critical, "S02.market", ...)
      pre = state@H-1
      if pre.hasBadDebt():
          emit Finding(critical, "S02.baddebt", ...)
      root  = pre.nextSettlementBorrower(0)
      quote = pre.settlementFor(borrower, 0)            # SettlementQuote{personal, queueRoot}; budget 0 = full policy quote
      allowed = quote.personal.borrowShares
      if borrower == root: allowed = max(allowed, quote.queueRoot.borrowShares)
      if borrowSharesCanceled > allowed + ONE_SHARE_STEP:
          emit Finding(critical, "S02.cut", evidence={market, borrower, cut=borrowSharesCanceled,
              allowed, txHash})
  ```

- **False positive:** state changes earlier in the same transaction (for example a liquidity withdrawal) can legally raise the allowance measured at the parent block. Small overshoot → check the transaction trace before paging.
- **Runbook:** request CircuitBreaker pause; trace the transaction; an over-large cut allowed by the controller is a controller bug, fixed by upgrade before resume.
- **Example message:**

  ```
  🚨 LL-SETTLE-POLICY-BREACH · WETH/wstETH · settlement cut 3.2× the policy allowance
  Settle at block 21,451,020: borrower 0x44de…a9c0 cut by 1,910e6 borrow shares.
  Parent-block allowance: personal 0, queue-root 601e6 (borrower was root). Overshoot 3.2×, far beyond same-tx drift.
  Act: request CircuitBreaker pause → breaker committee; trace tx.
  Not an attack if: a large same-tx liquidity withdrawal raised the root allowance. Trace shows none.
  Related: LL-EXIT-PRESSURE 1 h ago.
  tx 0x08…4e · runbook <link>
  ```

### S03. Controller and core disagree (`LL-CONTROLLER-CORE-DIVERGED`)

- **Severity:** critical. **Cadence:** event-first over the ledger.
- **Scope:** the event ledger, both sides. No borrower polling.
- **Rationale:** the settlement queue is ordered from the controller's collateral mirror. Divergence surfaces to users only as `PositionAccountingMismatch` reverts, which cost gas to hit; the ledger detects it in the block it appears.
- **Trigger logic:**

  ```text
  on any core or controller event naming a borrower:
      ledger.apply(event)                       # core side: collateral, borrowShares
      if event carries a controller position payload:   # CollateralActivating/Activated/Dusted/Demoted/Drained
          p = event.position
          if p.dust + p.activating > ledger.collateral(borrower)
             OR (p.dust, p.activating) != ledger.predictedBuckets(borrower):
              # confirm with one positionOf/core.position read pair at the latest block
              if confirmed: emit Finding(critical, "S03", evidence={market, borrower,
                  controllerBuckets, coreCollateral, txHash})
  ```

- **Runbook:** request CircuitBreaker pause; the market will start reverting user actions on its own; expect an upgrade.
- **Example message:**

  ```
  🚨 LL-CONTROLLER-CORE-DIVERGED · WETH/wstETH · controller mirror off by 12 wstETH
  Borrower 0x90ab…11f2: controller buckets sum 812 wstETH, core stores 800 wstETH.
  Queue ordering is now wrong; user calls will begin reverting with PositionAccountingMismatch.
  Act: request CircuitBreaker pause → breaker committee. Upgrade expected before resume.
  Not an attack if: nothing known. Event ledger agrees with the chain for every other borrower.
  Related: none.
  borrower <link> · runbook <link>
  ```

### S04. A hard cap stopped holding (`LL-MARKET-CAPS-BREACHED`)

- **Severity:** high. **Cadence:** event-first + every-block totals check.
- **Scope:** core `Supply` events; `market(id)` totals.
- **Trigger logic:**

  ```text
  on event Supply(id, caller, onBehalf, assets, shares):
      if maxDeposit()@H-1 == 0:                  # cap room was zero at the parent block
          emit Finding(high, "S04.supply", evidence={market, assets, cap, txHash})

  m = market(id)@H                               # controller's own check, virtual offsets included
  if m.totalBorrowShares + 1e6 > MAX_BORROW_SHARE_RATE * (m.totalBorrowAssets + 1)
     AND no Liquidate event in block H:          # liquidation is exempt from the rate cap
      emit Finding(high, "S04.rate", evidence={market, totals})
  ```

- **False positive:** a `SupplyCapSet` raising the cap in the same block (checked automatically).
- **Runbook:** reproduce the check off-chain; if confirmed, steward freeze while the team scopes the bug.
- **Example message:**

  ```
  🟠 LL-MARKET-CAPS-BREACHED · WETH/wstETH · deposit above the supply cap
  Supply of 500 WETH at block 21,452,700; parent-block cap room was 0 (cap 20,000, supplied 20,000).
  The controller should have reverted this.
  Act: reproduce the check off-chain; if confirmed, steward freeze while the team investigates → protocol team.
  Not an attack if: SupplyCapSet in the same block raised the cap first. Checked: none.
  tx 0x3c…90 · runbook <link>
  ```

### S05. Liquidation wave (`LL-LIQUIDATION-WAVE`)

- **Severity:** medium. **Cadence:** event-first, aggregated.
- **Scope:** core `Liquidate` events.
- **Trigger logic:**

  ```text
  on event Liquidate(id, caller, borrower, repaidAssets, repaidShares,
                     seizedAssets, badDebtAssets, badDebtShares):
      if badDebtShares > 0: escalate via S01 / V02, not here
      window.add(event)
  if count(window, liquidationWaveWindow) ≥ 2:
      emit Finding(medium, "S05", evidence={market, count, totals, borrowers})
  # single liquidations are digest lines
  ```

- **Rationale:** with an accounting-rate oracle and no-penalty settlement, liquidations should be rare; a cluster means something moved.
- **Example message:**

  ```
  🔵 LL-LIQUIDATION-WAVE · WETH/wstETH · 3 liquidations in 40 m
  Borrowers 0x11…, 0x5d…, 0x77…: repaid 1,410 WETH total, seized 1,835 wstETH. badDebtShares = 0 in all.
  Likely cause: strike-delays left thin active collateral (2 of 3 were flagged this week).
  Act: check the positions for a common factor → protocol team.
  Related: LL-STRIKES-NEAR-QUORUM 2 d ago.
  list <link>
  ```

---

## 8. Vault & Exit Plane (V)

### V01. Vault shares lost their backing (`LL-VAULT-BACKING-BROKEN`)

- **Severity:** critical. **Cadence:** every block.
- **Scope:** every vault.
- **Trigger logic:**

  ```text
  if vault.managedSupplyShares()@H > core.position(marketId, vault).supplyShares@H:
      emit Finding(critical, "V01", evidence={vault, managed, corePosition, gap})
  on ERC4626 event Deposit(caller, owner, assets, shares) where shares == 0 AND assets > 0:
      emit Finding(critical, "V01.zeromint", evidence={vault, assets, txHash})
  # more core shares than managed is fine: that is a donation
  ```

- **Rationale:** the vault's records claim more core supply shares than the core says it owns; the share price is then wrong and value can drain.
- **Runbook:** request CircuitBreaker pause (a pause zeroes every vault limit); rebuild vault accounting off-chain; expect an upgrade.
- **Example message:**

  ```
  🚨 LL-VAULT-BACKING-BROKEN · WETH/wstETH vault · vault claims more shares than it owns
  managedSupplyShares = 18,400,001e6 > core position = 18,399,988e6 (gap 13e6 shares ≈ 13 WETH).
  Vault share price is now unreliable; conversions are wrong.
  Act: request CircuitBreaker pause → breaker committee. Then rebuild vault accounting off-chain.
  Not an attack if: nothing known. Re-checked at latest block: still true.
  Related: none.
  vault <link> · runbook <link>
  ```

### V02. Vault share price dropped (`LL-VAULT-SHARE-PRICE-DROP`)

- **Severity:** critical. **Cadence:** every block.
- **Scope:** every vault.
- **Trigger logic:**

  ```text
  sp = vault.convertToAssets(10 ** vault.decimals())@H
  if sp < prev(sp) * (1 - sharePriceDropToleranceBps / 10_000):     # draft tolerance 0
      cause = Liquidate event in block H with badDebtShares > 0
      emit Finding(critical, "V02", evidence={vault, prev(sp), sp, dropBps,
          cause | "none"})
  ```

- **Rationale:** interest only raises the share price; settlement at the oracle price must not lower it. A drop is a realized bad-debt loss (explainable) or broken accounting (respond as V01).
- **Runbook:** loss case → quantify, link S01 history, inform users. No known cause → request CircuitBreaker pause; rebuild vault accounting off-chain.
- **Example message:**

  ```
  🚨 LL-VAULT-SHARE-PRICE-DROP · WETH/wstETH vault · share price fell 0.31%
  1 share: 1.04210 → 1.03887 WETH at block 21,450,131.
  Cause found: Liquidate in same block with badDebtShares = 58,100e6 (≈ 60.4 WETH socialized).
  Lender loss is real and quantified; accounting is consistent.
  Act: publish loss note (60.4 WETH, 0.31%); link S01 history → protocol team. If cause had been none: pause.
  Related: LL-MARKET-BAD-DEBT 22 m ago.
  tx 0xde…77 · runbook <link>
  ```

### V03. Exits are cutting borrowers (`LL-EXIT-PRESSURE`)

- **Severity:** high. **Cadence:** event-first, aggregated per `exitPressureWindow`.
- **Scope:** every vault.
- **Trigger logic:**

  ```text
  on event FallbackExit(caller, owner, receiver, sharesBurned, collateralSeized, debtCanceled)
    where collateralSeized > 0:                        # the settle leg is in use
      emit Finding(high, "V03", evidence={vault, window totals: debtCanceled,
          collateralSeized, owners, utilization@H})
  # value-bearing: first event fires; then at most once per exitPressureWindow with totals
  ```

- **Rationale:** exiting lenders are being paid in borrower collateral. Legal under stress, and still needs review: visible cuts can push more lenders to exit, and every cut de-leverages a borrower at the oracle price.
- **Runbook:** verify cuts are policy-sized (S02 audits each one); prepare lender comms; steward review if inflow is also unusual.
- **Example message:**

  ```
  🟠 LL-EXIT-PRESSURE · WETH/wstETH · lender exits are settling borrower positions
  Last 4 h: 3 fallbackExit calls used the settle leg. Cut: 2,140 WETH debt cancelled,
  2,720 wstETH collateral handed to exiting lenders (at oracle rate, no penalty).
  Utilization 99.6%. Queue root LTV 76%, 4 points below the market LLTV.
  Act: verify cuts look policy-sized (auto-checked, see S02); prepare lender comms; steward review if inflow is also unusual.
  Related: LL-EXITBOOK-MAX-FEE 3 h ago, LL-UTILIZATION-HIGH 9 h ago.
  vault <link> · runbook <link>
  ```

### V04. Utilization stays near 100% (`LL-UTILIZATION-HIGH`)

- **Severity:** high. **Cadence:** every 12 blocks.
- **Scope:** every market.
- **Trigger logic:**

  ```text
  u = market(id).totalBorrowAssets * 10_000 / market(id).totalSupplyAssets  @H
  if u ≥ utilizationHighBps for utilizationHighWindow:       # draft: ≥ 99% for 6 h
      emit Finding(high, "V04", evidence={market, u, window, borrowAprSeries})
  # re-arm after the same window below the bound
  ```

- **False positive:** a rate spike elsewhere making this market's borrow cheap; the IRM should correct within hours (check `BorrowRateUpdate`).
- **Runbook:** watch exit pressure (V03 is the next stage); brief the steward if inflow is also unusual.
- **Example message:**

  ```
  🟠 LL-UTILIZATION-HIGH · WETH/wstETH · 99.4% utilization for 6 h
  Supply 18,400 WETH, borrowed 18,290 WETH. Normal withdrawals above 110 WETH now fail.
  Borrow APR climbed 4.1% → 9.8% over the window (IRM responding).
  Act: watch exit pressure; brief the steward if inflow is also unusual → protocol team.
  Related: none.
  market <link> · runbook <link>
  ```

### V05. Exit book fills at max fee (`LL-EXITBOOK-MAX-FEE`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every exit book.
- **Trigger logic:**

  ```text
  on event ExitProcessed(id, executor, rewardRecipient, asset, filledAssets,
                         sharesBurned, fillerReward, serviceCut):
      ramp = request(id).ramp                     # cached from ExitRequested
      if fillerReward * 1e18 / filledAssets ≥ ramp.endRate:
          window.add(fill)
  if count(window, maxFeeFillWindow) ≥ maxFeeFillCount:
      emit Finding(high, "V05", evidence={book, fills, rates, openRequests})
  ```

- **Rationale:** exits clear only at the top of the fee ramp (cap `MAX_PRIORITY_FEE` = 10%): exit demand exceeds liquidity.
- **Runbook:** compare with utilization and vault exits; draft lender comms before V03 starts.
- **Example message:**

  ```
  🟠 LL-EXITBOOK-MAX-FEE · WETH/wstETH · 3 exits filled at the maximum priority fee
  3 fills in 12 h paid the full endRate: 2.0%, 2.0%, 3.5% (caps chosen by requesters, global cap 10%).
  Total exited via book today: 1,240 WETH. Open requests: 5 for 2,100 WETH.
  Act: compare with utilization (99.4%) and vault exits; draft lender comms → protocol team.
  Related: LL-UTILIZATION-HIGH 2 h ago.
  book <link> · runbook <link>
  ```

### V06. Exit book paused or funds recovered (`LL-EXITBOOK-EMERGENCY`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every exit book.
- **Trigger logic:**

  ```text
  on event Paused(account) OR Unpaused(account)
       OR EtherRecovered(recipient, amount) OR ERC20Recovered(token, recipient, amount)
       OR ERC721Recovered(token, tokenId, recipient) OR ERC1155Recovered(token, tokenId, recipient, amount)
    where log.address ∈ EXIT_BOOKS:
      emit Finding(high, "V06", evidence={book, event, args, openRequests, txHash})
  ```

- **False positive:** scheduled maintenance or recovery of tokens sent by mistake; recovery must never touch active requests (compare amounts against open-request totals).
- **Runbook:** confirm intent with the pauser/recoverer owner; stranded open requests cannot be filled while paused; inform users.
- **Example message:**

  ```
  🟠 LL-EXITBOOK-EMERGENCY · WETH/wstETH book · book paused by 0xE11…9a0
  Paused at 11:20 UTC by the exit_book_pauser address. 5 open requests (2,100 WETH) cannot be filled while paused.
  Act: confirm intent with the pauser owner; if unintended, unpause path is <role per registry> → protocol team.
  Not an attack if: scheduled maintenance. Check the ops calendar.
  tx 0x77…b1 · runbook <link>
  ```

---

## 9. Emergency-Controls Plane (E)

### E01. Market paused (`LL-MARKET-PAUSED`)

- **Severity:** critical. **Cadence:** event-first.
- **Scope:** every controller.
- **Trigger logic:**

  ```text
  on event Paused(duration) where log.address ∈ CONTROLLERS:
      emit Finding(critical, "E01", evidence={market, duration,
          resumeAt=getResumeSinceTimestamp()@H, caller})
  ```

- **Rationale:** the breaker fired: an incident response started, or the breaker misfired. Everything stops, including lender exits; nobody can end the pause early (`RESUMER_ROLE` unheld).
- **Runbook:** confirm intent with the breaker committee; start the incident process; publish the resume time. If the committee did not fire it, treat the breaker key as compromised.
- **Example message:**

  ```
  🚨 LL-MARKET-PAUSED · WETH/wstETH · CircuitBreaker paused the market for 21 d
  Paused(1,814,400 s) at 16:44 UTC. Resume: Sep 3, 16:44 UTC. No early resume exists (RESUMER_ROLE unheld).
  All market actions and vault exits now revert.
  Act: confirm intent with breaker committee; start incident process; publish resume time → on-call.
  Not an attack if: the committee confirms. If they did not fire it: treat the breaker key as compromised.
  Related: (whatever paged in the last hour appears here)
  tx 0xcc…19 · runbook <link>
  ```

### E02. Pause ends soon (`LL-PAUSE-ENDING`)

- **Severity:** high. **Cadence:** every 100 blocks while any market is paused.
- **Scope:** every paused controller.
- **Rationale:** pause expiry emits **no event**; the market starts working again on its own. If the incident is not fixed by then, it reopens broken.
- **Trigger logic:**

  ```text
  for offset in pauseEndingOffsets:            # draft: 48 h, 6 h
      if getResumeSinceTimestamp()@H - now crosses offset:
          emit Finding(high, "E02", evidence={market, resumeAt, incidentStatus})
  ```

- **Runbook:** confirm the fix lands before resume, or arrange a re-pause at expiry; align comms.
- **Example message:**

  ```
  🟠 LL-PAUSE-ENDING · WETH/wstETH · market reopens in 48 h, is the incident fixed?
  Pause from Aug 13 expires Thu 16:44 UTC. Reopening is silent: no event, everything resumes at once.
  Incident #2026-08-13-oracle: upgrade motion #431 is still in its objection window (ends Wed 09:00).
  Act: confirm the upgrade lands before resume, or ask the breaker committee to re-pause at expiry → protocol team.
  Related: LL-MARKET-PAUSED 19 d ago.
  tracker <link> · runbook <link>
  ```

### E03. Market resumed early (`LL-MARKET-RESUMED`)

- **Severity:** critical. **Cadence:** event-first.
- **Scope:** every controller.
- **Trigger logic:**

  ```text
  on event Resumed() where log.address ∈ CONTROLLERS:
      if now < recordedResumeAt:                # early resume needs RESUMER_ROLE, unheld by design
          emit Finding(critical, "E03", evidence={market, recordedResumeAt, caller,
              resumerGrantHistory (G05)})
  ```

- **Runbook:** no G05-recorded grant → key compromise: request immediate re-pause. Granted → verify the original incident is fixed.
- **Example message:**

  ```
  🚨 LL-MARKET-RESUMED · WETH/wstETH · pause ended 12 d early
  Resumed() at 08:02 UTC; recorded resume time was Sep 3. Caller holds RESUMER_ROLE granted 2 h ago (LL-ROLE-DRIFT fired; no motion on record).
  All market risk is live again and the incident fix has not shipped.
  Act: request immediate re-pause; treat the resumer grant as key compromise → on-call + breaker committee.
  Related: LL-ROLE-DRIFT 2 h ago, LL-MARKET-PAUSED 9 d ago.
  tx 0x0d…5a · runbook <link>
  ```

### E04. Market frozen (`LL-MARKET-FROZEN`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every controller.
- **Trigger logic:**

  ```text
  on event FrozenSet(true, account):
      emit Finding(high, "E04", evidence={market, account, exitPathsStatus})
  ```

- **Rationale:** a steward acted: new borrows, debt-withdrawals, and maturation stopped; repay, liquidate, settle, and debt-free withdrawal stay open.
- **Runbook:** get the steward's reason; agree the next step (flags, pause escalation, or an unfreeze motion); verify exit paths still work.
- **Example message:**

  ```
  🟠 LL-MARKET-FROZEN · WETH/wstETH · steward froze the market
  FrozenSet(true) at 13:05 UTC via RiskStewardDashboard (steward 0x5t…3w).
  Stopped: new borrows, collateral withdrawal with debt, maturation. Open: repay, liquidate, settle, exits.
  Act: get the steward's reason; agree next step (flags / pause / unfreeze motion) → protocol team.
  Not an attack if: it is the steward committee doing its job. Confirm on the steward channel.
  Related: LL-STETH-DEPEG 25 m ago.
  tx 0x83…7c · runbook <link>
  ```

### E05. Market unfrozen (`LL-MARKET-UNFROZEN`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every controller.
- **Trigger logic:**

  ```text
  on event FrozenSet(false, account):
      emit Finding(high, "E05", evidence={market, account, freezeReasonStatus})
  ```

- **Runbook:** unfreeze must come through `LidoLendOwner` after a motion; verify the motion and that the freeze reason is resolved.
- **Example message:**

  ```
  🟠 LL-MARKET-UNFROZEN · WETH/wstETH · freeze lifted
  FrozenSet(false) at 10:00 UTC via LidoLendOwner.
  Freeze reason (June inflow anomaly) closed as false alarm in the incident log.
  Act: confirm the log entry and resume normal watch → protocol team.
  tx 0xef…40
  ```

### E06. Steward tightened risk (`LL-RISK-TIGHTENED`)

- **Severity:** medium. **Cadence:** event-first.
- **Scope:** the dashboard.
- **Trigger logic:**

  ```text
  on event ActivationDelaysIncreased(marketId, newMin, newMax, newMaxQuorumDelay)
       OR ActivatingLockIncreased(marketId, newAmount, newDuration)
       OR InstantActivationRevoked(marketId, caller)
       OR MarketStewardSet(marketId, steward, enabled):
      emit Finding(medium, "E06", evidence={event, args})
      update config snapshot / steward baseline after review
  ```

- **Rationale:** tighten-only by construction. The question is why the steward acted.
- **Runbook:** ask the steward what they saw; check A-plane alerts for the same window.
- **Example message:**

  ```
  🔵 LL-RISK-TIGHTENED · WETH/wstETH · steward raised activation delays
  ActivationDelaysIncreased: max delay 2 h → 4 h, at 17:20 UTC.
  Act: ask the steward what they saw; check A-path alerts for the same window → protocol team.
  Related: LL-INFLOW-SATURATED 1 h ago.
  tx 0x35…88
  ```

### E07. The breaker cannot pause (`LL-BREAKER-DISARMED`)

- **Severity:** high. **Cadence:** every 100 blocks.
- **Scope:** every controller + the CircuitBreaker (ABI from the pinned `lib/circuit-breaker` version).
- **Trigger logic:**

  ```text
  for c in CONTROLLERS:
      alive = c.hasRole(PAUSER_ROLE, BREAKER)@H
              AND BREAKER not expired @H AND heartbeat deadline not passed @H
      if NOT alive:
          emit Finding(high, "E07", evidence={controller, cause: role|expiry|heartbeat})
  ```

- **Runbook:** schedule the re-arm with the breaker admin; re-grant `PAUSER_ROLE`; tell the steward committee that freeze is the only fast control until then (and freeze does not stop settlement or liquidation).
- **Example message:**

  ```
  🟠 LL-BREAKER-DISARMED · protocol · no live pauser on WETH/wstETH controller
  CircuitBreaker heartbeat deadline passed at 00:00 UTC; its pause power no longer works. PAUSER_ROLE has no other holder.
  Fast emergency stop is gone. Steward freeze remains (does not stop settlement/liquidation).
  Act: schedule the re-arm call with the breaker admin; tell the steward committee that freeze is the only fast control for now → protocol team.
  Related: LL-BREAKER-HEARTBEAT-DUE fired 31 d ago and 7 d ago.
  runbook <link>
  ```

### E08. Breaker upkeep due (`LL-BREAKER-HEARTBEAT-DUE`)

- **Severity:** medium. **Cadence:** every 100 blocks; repeats weekly until fed.
- **Scope:** the CircuitBreaker.
- **Trigger logic:**

  ```text
  if breakerHeartbeatDeadline@H - now < breakerHeartbeatWarning:   # draft 30 d of 365 d
      emit Finding(medium, "E08", evidence={deadline, daysLeft})
  ```

- **Runbook:** put the heartbeat call on the governance calendar (E07 is what happens if this is missed).
- **Example message:**

  ```
  🔵 LL-BREAKER-HEARTBEAT-DUE · protocol · breaker heartbeat due in 30 d
  CircuitBreaker heartbeat deadline: Sep 13. If nobody calls the heartbeat, the pause power expires (see LL-BREAKER-DISARMED).
  Act: put the heartbeat call on the governance calendar → protocol team.
  runbook <link>
  ```

---

## 10. Guardian Plane (W)

### W01. Quorum frontier stalled (`LL-GUARDIAN-FRONTIER-STALLED`)

- **Severity:** high. **Cadence:** every 12 blocks.
- **Scope:** every guardian registry.
- **Rationale:** the frontier is the on-chain proof that a quorum of guardians is scanning the chain; a stalled frontier means that proof stopped. Where `maxGuardiansQuorumDelay > 0`, maturation also halts.
- **Trigger logic:**

  ```text
  if now - getQuorumFrontier()@H > frontierStallWindow:       # draft 6 h
      emit Finding(high, "W01", evidence={registry, frontier, heartbeatAges,
          activatingTotalAcrossMarkets(ledger)})
  # re-arm when the frontier advances
  ```

- **Runbook:** page guardian operators to heartbeat (anyone can then call `syncQuorumFrontier`). If the committee is down during heavy inflow, ask the steward to freeze: nobody is reviewing the deposits inside the delay window.
- **Example message:**

  ```
  🟠 LL-GUARDIAN-FRONTIER-STALLED · guardians · no quorum coverage for 6 h
  getQuorumFrontier() = 07:55 UTC, now 14:02. Quorum 3 of 5; last heartbeats: 0xAA 6.1 h, 0xBB 6.3 h, 0xCC 26 h ago.
  Meanwhile: 6,200 wstETH is activating in WETH/wstETH (see maturity list).
  Act: page guardian operators to heartbeat; if coverage stays down during this inflow, ask the steward to freeze → guardian ops.
  Related: LL-MATURITY-WAVE 2 h ago, LL-GUARDIAN-SILENT (0xCC) 20 h ago.
  registry <link> · runbook <link>
  ```

### W02. One guardian silent (`LL-GUARDIAN-SILENT`)

- **Severity:** medium. **Cadence:** every 100 blocks.
- **Scope:** every committee member.
- **Trigger logic:**

  ```text
  for g in getGuardians()@H:
      if now - getHeartbeat(g)@H > guardianSilentWindow AND frontier still fresh:
          emit Finding(medium, "W02", evidence={guardian, lastHeartbeat, activeCount, quorum})
  # re-arm on the next heartbeat
  ```

- **Rationale:** the committee is losing redundancy before W01 fires.
- **Example message:**

  ```
  🔵 LL-GUARDIAN-SILENT · guardians · 0xCC…03 quiet for 26 h
  Last heartbeat Aug 12, 12:00 UTC. Frontier still fresh (4 of 5 active, quorum 3).
  Act: ping the operator; check its delegate key → guardian ops.
  registry <link>
  ```

### W03. Guardian set or quorum changed (`LL-GUARDIAN-SET-CHANGED`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every guardian registry.
- **Trigger logic:**

  ```text
  on event GuardianAdded(guardian) OR GuardianRemoved(guardian)
       OR QuorumSet(quorum) OR SuspectWindowSet(suspectWindow):
      count = getGuardianCount()@H; q = getQuorum()@H
      flags = {bansImpossible: q > count, noRedundancy: count ≤ q,
               retroactiveBans: accounts whose strikes now reach a lowered q (list when cheap)}
      emit Finding(high, "W03", evidence={event, args, count, q, flags})
  # DelegateSet is a digest line
  ```

- **Runbook:** verify the motion; an unreachable quorum means the market runs without its ban power: demand an immediate fix.
- **Example message:**

  ```
  🟠 LL-GUARDIAN-SET-CHANGED · guardians · quorum raised 3 → 4 with only 4 members
  QuorumSet(4) at 12:30 UTC via LidoLendOwner. Members: 4. Any single member outage now makes bans impossible.
  No accounts reach ban at the new quorum retroactively.
  Act: flag the redundancy gap to governance; propose a 5th member or quorum 3 → protocol team.
  tx 0x60…aa · runbook <link>
  ```

### W04. Ban without a quorum (`LL-FORCED-BAN`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every guardian registry.
- **Trigger logic:**

  ```text
  on event Banned(marketId, account):
      if getFlaggedBy(marketId, account)@H-1 count < getQuorum()@H-1:
          emit Finding(high, "W04", evidence={market, account, flagsAtParent, quorum,
              ACCESS_LIMITER holders (G05 history)})
  ```

- **Rationale:** a ban below quorum means `ACCESS_LIMITER_ROLE` acted. It is unheld at launch: either a G05-recorded grant is seeing first use, or something is very wrong.
- **Runbook:** confirm the holder and the case with the committee; if nobody should hold it, respond as key compromise (G05 path).
- **Example message:**

  ```
  🟠 LL-FORCED-BAN · WETH/wstETH · account banned without guardian quorum
  Banned(0x7a3f…9e12) at 15:00 UTC; parent-block flags 1 of quorum 3 → ACCESS_LIMITER_ROLE was used.
  Role grant on record: motion #430 (emergency committee), LL-ROLE-DRIFT fired 3 d ago, matched.
  Act: confirm this use with the committee; log the case → protocol team.
  Related: LL-ROLE-DRIFT 3 d ago, LL-MATURITY-WAVE 4 h ago.
  tx 0x72…19 · runbook <link>
  ```

### W05. Account unbanned (`LL-ACCOUNT-UNBANNED`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** every guardian registry.
- **Trigger logic:**

  ```text
  on event Unbanned(marketId, account, by):
      emit Finding(high, "W05", evidence={market, account, by})
  ```

- **Rationale:** unban restores borrowing and clears the account's flags: its guardian history is erased. Governance-gated.
- **Runbook:** verify the motion and the case (false alarm vs recovered account); ask guardians to watch the account.
- **Example message:**

  ```
  🟠 LL-ACCOUNT-UNBANNED · WETH/wstETH · 0x22c1…07dd may borrow again
  Unbanned at 09:40 UTC via LidoLendOwner (case on record: compromised account recovered by owner, keys rotated).
  All prior flags cleared: guardian history on this account is reset.
  Act: confirm case notes; ask guardians to watch the account for a week → protocol team.
  tx 0x8b…36 · runbook <link>
  ```

### W06. Ban latched by quorum (`LL-ACCOUNT-BANNED`)

- **Severity:** medium. **Cadence:** event-first.
- **Scope:** every guardian registry.
- **Trigger logic:**

  ```text
  on event Banned(marketId, account):
      if getFlaggedBy(marketId, account)@H-1 count ≥ getQuorum()@H-1:
          emit Finding(medium, "W06", evidence={market, account, debt(ledger),
              collateral(ledger)})
  ```

- **Rationale:** the system worked as designed: the account cannot borrow, its collateral stops maturing, exit stays open.
- **Runbook:** archive the evidence; check the account's debt is zero or well covered; expect re-entry from fresh addresses (A02 helps).
- **Example message:**

  ```
  🔵 LL-ACCOUNT-BANNED · WETH/wstETH · quorum banned 0x7a3f…9e12
  3rd flag latched the ban at 14:50 UTC. Debt 0; 4,000 wstETH collateral frozen out of maturation, withdrawable.
  Act: archive evidence; expect re-entry from fresh addresses → protocol team.
  Related: LL-STRIKES-NEAR-QUORUM 1 h ago, LL-MATURITY-WAVE 3 h ago.
  account <link>
  ```

### W07. Guardian flagged an account (`LL-ACCOUNT-FLAGGED`)

- **Severity:** medium. **Cadence:** event-first; one incident per (market, account).
- **Scope:** every guardian registry.
- **Rationale:** visibility, not action. The first flag is the earliest human signal in the pipeline: a guardian's screening found something worth a strike. The protocol has already responded (each strike extends the account's activation delay by `delayPerStrike`), so nothing needs to be done. The alert opens the story that A04 and W06 continue, so a later ban lands with context instead of surprising the channel.
- **Trigger logic:**

  ```text
  on event Flagged(marketId, account, guardian, actor, strikes):
      if strikes == 1:                              # first flag on this account
          emit Finding(medium, "W07", evidence={market, account, guardian, actor,
              strikes, quorum, position(ledger), unlock shift})
      # strikes 2 .. quorum−2 update the same incident; quorum−1 is A04's job
      # while A04's wave form is active, single-flag messages fold into the wave
  on event Unflagged(...) reaching strikes == 0: close the incident (digest line)
  ```

- **Runbook:** none required; this alert exists for visibility. Optional: read the guardian's case note; watch for further strikes.
- **Example message:**

  ```
  🔵 LL-ACCOUNT-FLAGGED · WETH/wstETH · first guardian flag on 0x7a3f…9e12
  Flagged by guardian 0xAA…01 (delegate 0xD1…7c) at 14:02 UTC; strikes 1 of quorum 3.
  Position: 4,000 wstETH activating, debt 0; unlock pushed 15:42 → 17:42 UTC (+2 h per strike).
  For visibility only; no response needed. LL-STRIKES-NEAR-QUORUM fires one flag before a ban.
  Related: LL-INFLOW-SATURATED 1 h ago.
  account <link>
  ```

### W08. Guardian marked an account suspect (`LL-ACCOUNT-SUSPECTED`)

- **Severity:** medium. **Cadence:** event-first; one incident per (market, account).
- **Scope:** every guardian registry.
- **Rationale:** visibility, not action. The suspect mark is the guardians' softer signal: no quorum, no ban path. Each active mark adds `delayPerSuspect` to the unlock of the account's activating collateral, and the mark lapses on its own after `suspectWindow` (cap 30 d). A suspect mark often comes before flags; the alert opens the same story that W07, A04, and W06 continue.
- **Trigger logic:**

  ```text
  on event Suspected(marketId, account, guardian, actor, timestamp):
      if getOpinion(marketId, account)@H-1 had no active suspect marks:   # first active mark
          emit Finding(medium, "W08", evidence={market, account, guardian, actor,
              suspectCount, suspectExpiryTimestamp, unlock shift, position(ledger)})
      # further marks by other guardians update the same incident
  on event SuspectCleared | SuspectPruned reaching suspectCount == 0,
     or the snapshot lapsing past suspectExpiryTimestamp:
      close the incident (digest line)
  ```

- **Runbook:** none required; this alert exists for visibility. Optional: read the guardian's case note; the mark ends in a clear, a lapse, or an escalation to flags (W07).
- **Example message:**

  ```
  🔵 LL-ACCOUNT-SUSPECTED · WETH/wstETH · first suspect mark on 0x7a3f…9e12
  Suspected by guardian 0xAA…01 (delegate 0xD1…7c) at 11:20 UTC; active marks: 1, lapses in 14 d (suspect window).
  Position: 4,000 wstETH activating, debt 0; unlock pushed 15:42 → 16:42 UTC (+1 h per active mark).
  For visibility only; no response needed. Suspects only extend the delay; escalation shows up as flags (LL-ACCOUNT-FLAGGED).
  Related: LL-INFLOW-SATURATED 2 h ago.
  account <link>
  ```

---

## 11. Periphery Plane (P)

Users reach the markets through **Bundler3** (stock Morpho `lib/bundler3`): `multicall(bundle)` runs a list of calls in one transaction, so one click can wrap, deposit, and borrow. The calls execute through two adapters in `src/adapters/`: `EthereumGeneralAdapter1` (token pulls, ETH staking, stETH wrapping, core supply/borrow/repay/withdraw) and `LidoLendVaultAdapter` (the vault's `fallbackExit`). To use them, accounts hold standing grants toward the adapters: ERC-20 allowances, vault-share allowances, and core authorizations (`setAuthorization`) that let the general adapter borrow and withdraw collateral on their behalf.

A grant to the real adapters is safe against third parties: an adapter spends a grant only for the account that initiated the bundle. Three loss cases remain: funds left inside the periphery between transactions (the next bundle can take them), grants farmed toward a lookalike address, and a farmed grant being exercised. The periphery contracts are not proxied, hold no roles, emit no events, and cannot be paused. P-plane responses are user communication, plus the guardian ban for borrow-side abuse: the borrow check rejects a banned caller.

### P01. Funds resting in the periphery (`LL-PERIPHERY-FUNDS-RESTING`)

- **Severity:** medium; high at or above `peripheryNotableValue`. **Cadence:** poll every 12 blocks.
- **Scope:** Bundler3 + both adapters, over the market loan and collateral tokens, stETH, vault shares, and native ETH.
- **Trigger logic:**

  ```text
  for c in periphery_set, t in watched_assets:
      bal = t.balanceOf(c)@H                     # native ETH via eth_getBalance
      if value_eth(bal) > peripheryDustValue and bal persists at next tick:
          emit Finding(medium|high, "P01", evidence={c, t, bal,
              funding tx (token Transfer logs into c)})
  ```

- **Rationale:** the periphery is designed to be empty between transactions; bundles move funds through it inside one transaction. Anything still there after the block ends can be taken by anyone: the adapters run `erc20Transfer` / `nativeTransfer` over their own balance for any bundle, and Bundler3 executes arbitrary calls. A resting balance means a bundle was built wrong (it left change behind) or someone sent tokens straight to a periphery address.
- **False positive:** stETH transfers leave 1–2 wei on the adapter by rounding; `peripheryDustValue` absorbs that. Mid-transaction balances never fire: only end-of-block balances are read.
- **Runbook:** locate the funding transaction. If a bundle left change, treat the bundle builder (frontend or SDK) as broken and fix it; aggregate repeats from the same builder into one incident. If a user sent tokens directly and the amount is meaningful, coordinate a rescue sweep at once; a rescue is itself a bundle anyone can run, so assume competition.
- **Example message:**

  ```
  🟠 LL-PERIPHERY-FUNDS-RESTING · protocol · 3.1 wstETH left in the general adapter
  EthereumGeneralAdapter1 balance at end of block 20,411,532: 3.1 wstETH (~3.7 ETH), above the 1 ETH notable line.
  Left by tx 0x4c…88 (bundle initiated by 0x91…2f). Anyone can take it with the next bundle; expected balance is zero.
  Act: trace the leaving bundle; if our frontend built it, fix the builder; coordinate a rescue sweep for the user → protocol team.
  Not an attack if: a direct transfer to the adapter address by mistake; wei-level stETH residue stays under the dust threshold.
  tx 0x4c…88 · runbook <link>
  ```

### P02. Approval or authorization farming (`LL-APPROVAL-FARMING`)

- **Severity:** high. **Cadence:** event-first.
- **Scope:** core `SetAuthorization`; ERC-20 `Approval` on every vault share token.
- **Trigger logic:**

  ```text
  on event SetAuthorization(caller, authorizer, authorized, true):
      if authorized == bundler3:                 # never legitimate: Bundler3 executes arbitrary calls
          emit Finding(high, "P02", evidence={authorizer, caller})
      elif authorized not in periphery_set:
          farm[authorized].add(authorizer)       # vault Approval(owner, spender, >0) feeds the same key
          if count(farm[authorized] within approvalFanoutWindow) >= approvalFanoutCount:
              emit Finding(high, "P02", evidence={authorized, grantors,
                  eth_getCode(authorized), contract age})
  # single grants to unknown targets: daily digest count, not an alert
  ```

- **Rationale:** an authorized manager can borrow and withdraw collateral on behalf of the authorizer; that is what the grant is for. Users should only ever authorize the general adapter. Many distinct accounts granting the same unknown address is the shape of a phishing campaign farming grants toward a lookalike adapter. P02 fires while the grants are still unexercised, before the drain (P03).
- **False positive:** a genuine new integration going live. Check: the target is a verified contract of a known project, announced, and its users confirm the flow.
- **Runbook:** no on-chain control revokes another account's grant. Publish a frontend warning and revoke instructions immediately; contact the granting accounts; watch the target address (its first position-moving call fires P03); prepare guardian flags for it.
- **Example message:**

  ```
  🟠 LL-APPROVAL-FARMING · protocol · 9 accounts authorized the same unknown manager in 6 h
  SetAuthorization(true) from 9 distinct accounts to 0xd00d…c0de since 08:10 UTC. Not the general adapter; deployed 2 d ago, code unverified.
  An authorized manager can borrow and withdraw collateral on behalf of all 9 accounts.
  Act: post the frontend warning + revoke guidance now; contact the accounts; watch for LL-UNKNOWN-MANAGER → protocol team.
  Not an attack if: a real integration launch. Check: verified contract of a known project, and its users confirm.
  grantors <link> · runbook <link>
  ```

### P03. Unknown manager operates positions (`LL-UNKNOWN-MANAGER`)

- **Severity:** medium on first sighting of a caller; high when one caller operates `managerFanoutCount`+ accounts within `managerFanoutWindow`, or the caller is a P02 target. **Cadence:** event-first.
- **Scope:** core `Borrow`, `Withdraw`, `WithdrawCollateral` events, every market.
- **Trigger logic:**

  ```text
  on event Borrow|Withdraw|WithdrawCollateral(id, caller, onBehalf, ...):
      if caller != onBehalf and caller != generalAdapter and caller not in botAllowlist:
          sightings[caller].add(onBehalf)
          if first sighting of caller: emit Finding(medium, "P03")
          if count(sightings[caller] within managerFanoutWindow) >= managerFanoutCount
             or caller in farm (P02):
              emit Finding(high, "P03", evidence={caller, accounts, amounts, receivers})
  ```

- **Rationale:** `caller != onBehalf` means a manager moved someone else's position through a core authorization. The only expected manager is the general adapter; the vault acts on its own position and never matches. One unknown caller operating many accounts is a drain executing, typically on grants farmed earlier (P02).
- **False positive:** a power user's own manager contract: one caller, one account, no P02 history. Confirm once, then add it to the bot's allowlist via a reviewed config update.
- **Runbook:** cross-check the caller against P02's farm list. On a match, treat it as an active drain of user wallets: publish revoke instructions; ask guardians to flag and ban the caller. A ban blocks further `borrow` where the caller is banned, market-wide; it does not block collateral withdrawals. A freeze stops all new borrows in the market. Collateral withdrawals stop only under the breaker pause, which also stops everyone else: weigh it.
- **Example message:**

  ```
  🟠 LL-UNKNOWN-MANAGER · WETH/wstETH · unknown caller borrowed on behalf of 3 accounts
  0xd00d…c0de (not the general adapter) called borrow onBehalf of 3 accounts in 40 m; 610 WETH total, receiver 0xd00d…c0de.
  All 3 granted authorization during the LL-APPROVAL-FARMING wave 2 d ago. The farmed grants are being exercised.
  Act: guardian flag/ban 0xd00d…c0de (the borrow check rejects a banned caller); publish revoke instructions → guardian committee.
  Not an attack if: a manager contract its owners set up on purpose; confirm with the affected accounts.
  Related: LL-APPROVAL-FARMING 2 d ago.
  txs <link> · runbook <link>
  ```

---

## 12. Ops

### OPS01. New market or component deployed (`LL-MARKET-CREATED`)

- **Severity:** medium. **Cadence:** event-first; repeats daily while uncovered.
- **Scope:** core; factories.
- **Trigger logic:**

  ```text
  on event CreateMarket(id, marketParams) OR SetMarketController(id, controller)
       OR EnableSettlement(id) OR factory deploy events:
      emit Finding(medium, "OPS01", evidence={id, marketParams, controller, coverageStatus})
  if market live AND not covered (no §2.5 column, no baseline rows): re-emit daily
  ```

- **Runbook:** onboard within 24 h: registry config, §2.5 worksheet column, §1.4 baseline rows, alert smoke test. The bot marks a market covered only after the worksheet exists.
- **Example message:**

  ```
  🔵 LL-MARKET-CREATED · protocol · new market USDY/USDC (id 0x7d…e2)
  CreateMarket + SetMarketController at 12:00 UTC. Oracle UsdyStableOracle, IRM router route #2.
  Monitoring status: NOT COVERED (no worksheet column, no baseline rows).
  Act: onboard within 24 h: worksheet, baseline, alert smoke test → monitoring team.
  registry <link> · runbook <link>
  ```

---

## 13. Excluded alerts (intentional)

Items considered and excluded, with justification:

- **Per-user transaction simulation** (staticcalling hypothetical user actions to find who would revert): unbounded and unnecessary; every policy revert has a state predicate the bot evaluates directly (S01, S03, S04).
- **Borrower-set polling** (iterating `positionOf` over all borrowers): replaced by the event ledger; the controller publishes its stored position in every activation event.
- **Single liquidations, large-but-legal actions, queue-root changes, personal settlement-LTV settings, guardian delegate rotations, exit-book allowlist changes, neutral config changes:** information without a decision → daily digest (§14).
- **Bot lifecycle alerts** (started / internal error): delivery-pipeline concern, owned by the monitoring platform, not this catalog.
- **Allowance enumeration on external tokens** (scanning WETH/wstETH `Approval` logs for third-party spenders): unbounded, and owned by the tokens rather than this protocol. The bot watches grant events only on the protocol's own contracts: core `SetAuthorization` and vault-share `Approval` (P02).
- **Bundle simulation** (decoding `multicall` payloads to pre-check outcomes): the adapters enforce initiator binding and slippage floors on-chain; the bot judges outcomes from the resulting core and vault events (P01–P03).
- **EasyTrack motion alerts** (`MotionCreated` decoding, objection-window countdowns): EasyTrack has its own dedicated alerting, and motions touching Lend surface there. The G-plane runbooks direct the responder to that channel for the matching-motion check; this bot does not subscribe to EasyTrack.
- **wstETH/stETH token and Lido core surface:** out of scope (§1.2).

---

## 14. Daily Digest

One `info` finding per market per day. Items with no decision go here; this keeps the alert channels small enough that responders read every alert. All values come from data the alerts already compute:

- TVL, supplied, borrowed, utilization (with day-over-day deltas)
- vault share price and 24 h change; oracle rate and 24 h change; reference-price discount and oracle gap (bps)
- inflow gauge (`currentInflow()` vs ceiling) and current activation delay
- activation pipeline: lots maturing in the next 24 h (count, total, largest, times)
- settlement queue: size (`settlementBorrowersCount()`), root borrower LTV vs LLTV
- exits: vault exits (liquid vs settle leg), exit-book requests/fills and top fee paid
- liquidations and settlements: count, volume, bad-debt flag
- guardians: heartbeat ages, frontier age; breaker: days to heartbeat deadline
- periphery: bundler/adapter balances (expected zero), single grants to non-registry targets (count), unknown-manager sightings
- notable single events: actions ≥ `notableAmount` or ≥ `notablePoolShareBps` of supply, bans/unbans, unflags to zero, suspect marks cleared or lapsed, delegate rotations, enacted config changes
- alert recap: everything that fired in 24 h, by severity

**Example:**

```
📊 Lend daily · WETH/wstETH · Aug 14
TVL 18,700 WETH (+1.6%) · borrowed 16,830 (util 90.0%, target 90) · share price 1.04213 (+2.1 bps)
Oracle 1.18424e36 (+1.0 bps, rebase 09:01 UTC) · stETH/ETH discount 14 bps · oracle gap 9 bps · inflow 2,300/10,000 wstETH · delay now 42 m
Maturing next 24 h: 4 lots, 900 wstETH total (largest 400, 18:40 UTC)
Queue: 41 borrowers · root LTV 74.2%, below the market LLTV · settlements today: 0 · liquidations: 1 (12 WETH, no bad debt)
Exits: vault 210 WETH all liquid-leg · book: 2 new (300 WETH), 3 fills, top fee 0.6%
Guardians: 5/5 heartbeats < 8 h, frontier 2 h · breaker heartbeat in 212 d
Periphery: balances 0 · grants to unknown targets: 0 · unknown managers: 0
Notable: 1,000 WETH supply by 0xfe…11 (5.3% of pool) · delegate rotated for guardian 0xBB
Alerts in 24 h: 🟠 1 (LL-INFLOW-SATURATED, resolved) · 🔵 2 · 🚨 0
```

---

## 15. Service / cadence breakdown

| Service | Mode | Cadence | Alerts owned |
| --- | --- | --- | --- |
| GovernanceWatcherSrv | event-first + per-100-block role/owner diff | every block (events) | G04–G09 |
| ProxyWatcherSrv | poll carousel + events | every 100 blocks | G01–G03 |
| OracleWatcherSrv | per-block price read | every block | O01, O02; O03/O04 every 12 |
| ReferencePriceSrv | independent price sources + ledger series | every 12 blocks | O05, O06 |
| ActivationWatcherSrv | event ledger + inflow tick | events; every 12 blocks | A01–A06 |
| SettlementWatcherSrv | event-first + per-block `hasBadDebt` | every block | S01–S05 |
| VaultWatcherSrv | per-block backing/share-price + events | every block | V01, V02; V03–V06 events/12 |
| EmergencyWatcherSrv | event-first + pause/breaker countdowns | events; every 100 blocks | E01–E08 |
| GuardianWatcherSrv | event-first + frontier/heartbeat ticks | every 12 / 100 blocks | W01–W08 |
| PeripheryWatcherSrv | balance poll + ledger events | every 12 blocks; events | P01–P03 |
| OpsWatcherSrv | event-first + daily coverage check | events; daily | OPS01 |
| DigestSrv | daily aggregation | 1/day per market | DIGEST |

The event ledger is a shared component: every service reads it; only the ledger writer applies events.

---

## 16. Event signatures (Solidity ABI)

```solidity
// LidoLend core (EventsLib @ lido-lend ec71716)
event CreateMarket(Id indexed id, MarketParams marketParams);
event SetMarketController(Id indexed id, address indexed controller);
event EnableSettlement(Id indexed id);
event SetOwner(address indexed newOwner);
event SetFee(Id indexed id, uint256 newFee);
event SetFeeRecipient(address indexed newFeeRecipient);
event EnableIrm(address indexed irm);
event EnableLltv(uint256 lltv);
event SetAuthorization(address indexed caller, address indexed authorizer, address indexed authorized, bool newIsAuthorized);
event Supply(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);
event Withdraw(Id indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets, uint256 shares);
event Borrow(Id indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets, uint256 shares);
event Repay(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets, uint256 shares);
event SupplyCollateral(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets);
event WithdrawCollateral(Id indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets);
event Liquidate(Id indexed id, address indexed caller, address indexed borrower, uint256 repaidAssets, uint256 repaidShares, uint256 seizedAssets, uint256 badDebtAssets, uint256 badDebtShares);
event Settle(Id indexed id, address caller, address indexed onBehalf, address indexed borrower, address receiver, uint256 supplySharesBurned, uint256 borrowAssetsCanceled, uint256 borrowSharesCanceled, uint256 seizedAssets);
event FlashLoan(address indexed caller, address indexed token, uint256 assets);
event AccrueInterest(Id indexed id, uint256 prevBorrowRate, uint256 interest, uint256 feeShares);

// LidoLendMarketController (incl. PausableUntil)
event FrozenSet(bool frozen, address indexed account);
event Paused(uint256 duration);
event Resumed();
event SupplyCapSet(uint256 cap, address indexed account);
event InstantActivationSet(address indexed caller, bool enabled);
event GuardianSignalsSet(address indexed guardianSignals);
event CollateralActivationConfigSet(CollateralActivationConfig config);
event SettlementConfigSet(SettlementConfig config);
event SettlementLtvSet(address indexed borrower, uint256 ltv);

// CollateralActivationLib (emitted via the controller; `position` = stored buckets + timer)
event CollateralActivating(address indexed borrower, uint256 amount, Position position);
event CollateralActivated(address indexed borrower, uint256 amount, Position position);
event CollateralDusted(address indexed borrower, uint256 amount, Position position);
event CollateralDemoted(address indexed borrower, uint256 amount, Position position);
event CollateralDrained(address indexed borrower, uint256 amount, Position position);

// GuardianSignals
event Flagged(Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 strikes);
event Unflagged(Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 strikes);
event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint256 strikes);
event Suspected(Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 timestamp);
event SuspectCleared(Id indexed marketId, address indexed account, address indexed guardian, address actor);
event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);
event Banned(Id indexed marketId, address indexed account);
event Unbanned(Id indexed marketId, address indexed account, address indexed by);
event GuardianAdded(address indexed guardian);
event GuardianRemoved(address indexed guardian);
event DelegateSet(address indexed guardian, address indexed oldDelegate, address indexed newDelegate);
event QuorumSet(uint256 quorum);
event SuspectWindowSet(uint256 suspectWindow);
event Heartbeat(address indexed guardian, uint256 blockNumber, uint256 timestamp);
event QuorumFrontierAdvanced(address indexed caller, uint256 timestamp);

// LidoLendERC4626 (plus standard ERC-4626 Deposit/Withdraw and ERC-20 Transfer/Approval)
event FallbackExit(address indexed caller, address indexed owner, address indexed receiver, uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled);
event Settled(address indexed caller, address indexed owner, address indexed receiver, uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled);

// RiskStewardDashboard
event MarketStewardSet(Id indexed marketId, address indexed steward, bool enabled);
event ActivationDelaysIncreased(Id indexed marketId, uint256 newMinActivationDelay, uint256 newMaxActivationDelay, uint256 newMaxGuardiansQuorumDelay);
event ActivatingLockIncreased(Id indexed marketId, uint256 newAmount, uint256 newDuration);
event InstantActivationRevoked(Id indexed marketId, address indexed caller);

// Exit books (incl. AssetRecoverer, OZ Pausable)
event ExitRequested(uint256 indexed id, address indexed owner, address indexed receiver, address asset, uint256 assets, uint256 minFillAssets, uint256 maxShareBurn, PriorityRamp ramp, uint256 deadline);
event ExitProcessed(uint256 indexed id, address indexed executor, address indexed rewardRecipient, address asset, uint256 filledAssets, uint256 sharesBurned, uint256 fillerReward, uint256 serviceCut);
event ExitCancelled(uint256 indexed id);
event ServiceFeeSet(address indexed feeRecipient, uint256 serviceFee);
event MarketAllowedSet(Id indexed marketId, bool allowed);
event VaultAllowedSet(address indexed vault, bool allowed);
event Paused(address account);
event Unpaused(address account);
event EtherRecovered(address indexed recipient, uint256 amount);
event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);
event ERC721Recovered(address indexed token, uint256 tokenId, address indexed recipient);
event ERC1155Recovered(address indexed token, uint256 tokenId, address indexed recipient, uint256 amount);

// IRM (lido-lend-irm)
event MarketIrmSet(Id indexed id, address indexed irm);
event IrmConfigApplied(Id indexed marketId, address indexed config);
event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);
event ManagerSet(address indexed manager);
event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

// OssifiableProxy (ERC-1967)
event Upgraded(address indexed implementation);
event AdminChanged(address previousAdmin, address newAdmin);
event ProxyOssified();

// AccessControl — at every role-bearing contract
event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

// Bundler3 + adapters (lib/bundler3, src/adapters/): no events. The P plane reads
// periphery balances plus core and vault logs.

// CircuitBreaker: take the ABI from the pinned lib/circuit-breaker version
```
