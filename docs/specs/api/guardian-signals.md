<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# GuardianSignals

Guardian-committee signal layer over accounts, keyed per market. Each guardian is a single committee address that may appoint a **delegate** (at most one at a time) to act on its behalf: it raises signals (flag, suspect) and retracts them (unflag, unsuspect), and the delegate may act for it. A `quorum` of distinct guardians' flags latches a ban in the market it was raised in. The minimal read surface the controller depends on (`getOpinion`, `isBanned`) is {IGuardianSignalsView}; this interface adds the rest.

## Structs

### `BlockInfoWithHash`

```solidity
struct BlockInfoWithHash {
    bytes32 hash;
    uint40 number;
    uint40 timestamp;
}
```

Heartbeat payload: a scanned block plus its hash, validated against `blockhash(number)`. Only the `timestamp` is kept in storage (the frontier gates on time); `number` + `hash` prove the block is real and un-reorged, and `number` is re-emitted in the `Heartbeat` event for off-chain tooling.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `hash` | `bytes32` | The reported block hash, checked against `blockhash(number)`. |
| `number` | `uint40` | The block number, which may not exceed the current block. |
| `timestamp` | `uint40` | The block timestamp. |

### `GuardiansOpinion`

```solidity
struct GuardiansOpinion {
    bool banned;
    uint256 strikeCount;
    uint256 suspectCount;
    uint256 suspectExpiryTimestamp;
    uint256 quorumFrontierTimestamp;
}
```

Everything the controller reads about an account in one call, forwarded to the activation lib which owns the delay math. Returned by `getOpinion`.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `banned` | `bool` | Whether the account is banned (hard-blocks borrowing). |
| `strikeCount` | `uint256` | Raw guardian flags on the account. |
| `suspectCount` | `uint256` | Active suspect reports snapshotted at the last report/retraction. |
| `suspectExpiryTimestamp` | `uint256` | When the current suspect snapshot lapses (`suspectReportedAt + suspectWindow`); the activation lib applies the suspect surcharge only to lots whose activation started before this. |
| `quorumFrontierTimestamp` | `uint256` | The quorum-scan frontier timestamp. |

## Events

### `GuardianAdded`

```solidity
event GuardianAdded(address indexed guardian);
```

Emitted when a guardian is added.

### `GuardianRemoved`

```solidity
event GuardianRemoved(address indexed guardian);
```

Emitted when a guardian is removed.

### `DelegateSet`

```solidity
event DelegateSet(address indexed guardian, address indexed oldDelegate, address indexed newDelegate);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `guardian` | `address` | The guardian that changed its delegate. |
| `oldDelegate` | `address` | The previous delegate (zero if none). |
| `newDelegate` | `address` | The new delegate (zero to clear). |

Emitted when a guardian sets or clears its delegate.

### `QuorumSet`

```solidity
event QuorumSet(uint256 quorum);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `quorum` | `uint256` | The number of distinct guardians' flags that latches a ban. |

Emitted when the quorum changes.

### `SuspectWindowSet`

```solidity
event SuspectWindowSet(uint256 suspectWindow);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `suspectWindow` | `uint256` | The freshness horizon within which a suspect report still counts. |

Emitted when the suspect window is set.

### `Heartbeat`

```solidity
event Heartbeat(address indexed guardian, uint40 blockNumber, uint40 timestamp);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `guardian` | `address` | The guardian the scan is recorded for. |
| `blockNumber` | `uint40` | The block number reported as scanned past (carried for off-chain tooling). |
| `timestamp` | `uint40` | The reported block's timestamp; the quorum-scan frontier orders guardians by this value. |

Emitted when a guardian's liveness is recorded, directly or via `flag`/`suspect`.

### `Suspected`

```solidity
event Suspected(Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 timestamp);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market the report is scoped to. |
| `account` | `address` | The suspected account. |
| `guardian` | `address` | The reporting guardian. |
| `actor` | `address` | The caller that made the call (the guardian or its delegate). |
| `timestamp` | `uint256` | The report time, recorded so the report can be aged out of the suspect window. |

Emitted when a guardian reports an account as suspect (raises the activation delay, never bans).

### `SuspectCleared`

```solidity
event SuspectCleared(Id indexed marketId, address indexed account, address indexed guardian, address actor);
```

Emitted when a guardian's suspect report on an account is retracted.

### `SuspectPruned`

```solidity
event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);
```

Emitted when a suspect report cast by a removed guardian is pruned.

### `Flagged`

```solidity
event Flagged(Id indexed marketId, address indexed account, address indexed guardian, address actor, uint16 strikes);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id. |
| `account` | `address` | The flagged account. |
| `guardian` | `address` | The flagging guardian. |
| `actor` | `address` | The caller that made the call (the guardian or its delegate). |
| `strikes` | `uint16` | The account's flag count after the flag. |

Emitted when a guardian flags an account.

### `Unflagged`

```solidity
event Unflagged(Id indexed marketId, address indexed account, address indexed guardian, address actor, uint16 strikes);
```

Emitted when a guardian's flag is retracted.

### `FlagPruned`

```solidity
event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
```

Emitted when a flag cast by a removed guardian is pruned.

### `Banned`

```solidity
event Banned(Id indexed marketId, address indexed account);
```

Emitted when an account's ban latches, by quorum or by `ban`.

### `Unbanned`

```solidity
event Unbanned(Id indexed marketId, address indexed account, address indexed by);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market the ban was scoped to. |
| `account` | `address` | The unbanned account. |
| `by` | `address` | The `ACCESS_RESTORER_ROLE` holder that unbanned. |

Emitted when an account's ban is lifted.

## Errors

### `ZeroAddress`

```solidity
error ZeroAddress();
```

Thrown when a zero address is passed where an account or guardian is required.

### `BadQuorum`

```solidity
error BadQuorum();
```

Thrown when the quorum is zero or exceeds the guardian count.

### `WouldBreakQuorum`

```solidity
error WouldBreakQuorum();
```

Thrown when removing a guardian would drop the set below the quorum.

### `AlreadyGuardian`

```solidity
error AlreadyGuardian();
```

Thrown when adding a guardian that is already in the set.

### `Unauthorized`

```solidity
error Unauthorized();
```

Thrown when the caller is neither `onBehalf` nor its delegate, or when a non-guardian appoints a delegate.

### `NotGuardian`

```solidity
error NotGuardian();
```

Thrown when the target of a guardian-only management action is not a guardian.

### `MaxGuardiansReached`

```solidity
error MaxGuardiansReached();
```

Thrown when the guardian set is already at `MAX_GUARDIANS_COUNT`.

### `BlockInTheFuture`

```solidity
error BlockInTheFuture();
```

Thrown when a heartbeat reports a block number ahead of the current block.

### `TimestampInTheFuture`

```solidity
error TimestampInTheFuture();
```

Thrown when a heartbeat reports a timestamp ahead of the current block.

### `HeartbeatTimestampRegressed`

```solidity
error HeartbeatTimestampRegressed();
```

Thrown when a heartbeat reports a timestamp below the guardian's previous heartbeat.

### `InvalidBlockHash`

```solidity
error InvalidBlockHash();
```

Thrown when a heartbeat's reported hash does not match the block's hash.

### `SuspectWindowTooHigh`

```solidity
error SuspectWindowTooHigh();
```

Thrown when the suspect window exceeds `MAX_SUSPECT_WINDOW`.

## Functions

### `addGuardian`

```solidity
function addGuardian(address guardian) external;
```

Add `guardian` to the committee. Must be non-zero, not already a guardian, and within the cap.

### `removeGuardian`

```solidity
function removeGuardian(address guardian) external;
```

Remove `guardian` from the committee (reverts if it would drop the set below the quorum).

### `setDelegate`

```solidity
function setDelegate(address newDelegate) external;
```

Appoint (or clear, with the zero address) the caller-guardian's delegate — a hot key that may act on the guardian's behalf. Guardian-only. The guardian's signals and heartbeat are unaffected.

### `setQuorum`

```solidity
function setQuorum(uint256 newQuorum) external;
```

Set the quorum — the distinct guardians' flags that latch a ban.

### `setSuspectWindow`

```solidity
function setSuspectWindow(uint256 suspectWindow) external;
```

Set the suspect window — the freshness horizon within which a suspect report still counts. Never touches the guardian set. The per-flag and per-suspect delays live in the market's activation config.

### `getQuorum`

```solidity
function getQuorum() external view returns (uint256);
```

The quorum: distinct guardians' flags that latch a ban.

### `getSuspectWindow`

```solidity
function getSuspectWindow() external view returns (uint256);
```

The suspect window: the freshness horizon within which a suspect report still counts.

### `isGuardian`

```solidity
function isGuardian(address account) external view returns (bool);
```

Whether `account` is a current guardian.

### `getDelegate`

```solidity
function getDelegate(address guardian) external view returns (address);
```

The current delegate of `guardian`, or zero if none is set.

### `getDelegates`

```solidity
function getDelegates() external view returns (address[] memory guardians, address[] memory delegates);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `guardians` | `address[]` | The current guardian set. |
| `delegates` | `address[]` | Each guardian's delegate, aligned by index with `guardians`. |

The guardian set paired with each guardian's current delegate (zero if none), aligned by index.

### `getGuardianCount`

```solidity
function getGuardianCount() external view returns (uint256);
```

The number of guardians.

### `getGuardians`

```solidity
function getGuardians() external view returns (address[] memory);
```

The current guardian set.

### `heartbeat`

```solidity
function heartbeat(
    address onBehalf,
    BlockInfoWithHash calldata lastScannedBlock
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `onBehalf` | `address` | The guardian the scan is recorded for. |
| `lastScannedBlock` | `BlockInfoWithHash` | The block reported as scanned past. |

Record `onBehalf`'s last-scanned block, validated against its block hash and timestamp. Callable by `onBehalf` or its delegate; the record is keyed by the guardian. The quorum frontier is recomputed separately by `syncQuorumBlock`.

### `syncQuorumBlock`

```solidity
function syncQuorumBlock() external;
```

Recompute the quorum-scan frontier from current heartbeats and ratchet it up. Permissionless and monotonic.

### `getHeartbeat`

```solidity
function getHeartbeat(
    address guardian
) external view returns (uint40 timestamp);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `timestamp` | `uint40` | The last-scanned block timestamp. |

The Unix timestamp of the last block `guardian` reported scanning (0 if never, or not a guardian).

### `getHeartbeats`

```solidity
function getHeartbeats() external view returns (address[] memory guardians, uint40[] memory timestamps);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `guardians` | `address[]` | The current guardian set. |
| `timestamps` | `uint40[]` | Each guardian's last-scanned block timestamp, aligned by index with `guardians`. |

The guardian set paired with each guardian's last-scanned block timestamp, aligned by index.

### `getQuorumFrontier`

```solidity
function getQuorumFrontier() external view returns (uint40);
```

Highest block timestamp at least a quorum of guardians have ever scanned past. Monotonic.

### `flag`

```solidity
function flag(
    Id marketId,
    address onBehalf,
    address[] calldata accounts,
    BlockInfoWithHash calldata lastScannedBlock
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market to flag in. |
| `onBehalf` | `address` | The guardian the flags are recorded for. |
| `accounts` | `address[]` | The accounts to flag. |
| `lastScannedBlock` | `BlockInfoWithHash` | The heartbeat to record, or a zero-hash block to skip the heartbeat. |

Flag `accounts` in `marketId` on behalf of guardian `onBehalf`. Callable by `onBehalf` or its delegate. Per account a no-op when the guardian already flags it, so a batch never reverts on a skip. A non-zero `lastScannedBlock` hash also advances the guardian's heartbeat; a zero hash skips it.

### `unflag`

```solidity
function unflag(
    Id marketId,
    address onBehalf,
    address[] calldata accounts
) external;
```

Retract guardian `onBehalf`'s flags on `accounts` in `marketId`. Callable by `onBehalf` or its delegate. Per account a no-op when the guardian does not flag it. Never lifts a ban in effect: a currently-effective ban (including a quorum-derived one) survives the retraction.

### `suspect`

```solidity
function suspect(
    Id marketId,
    address onBehalf,
    address[] calldata accounts,
    BlockInfoWithHash calldata lastScannedBlock
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market to report in. |
| `onBehalf` | `address` | The guardian the reports are recorded for. |
| `accounts` | `address[]` | The accounts to report as suspect. |
| `lastScannedBlock` | `BlockInfoWithHash` | The heartbeat to record, or a zero-hash block to skip the heartbeat. |

Report `accounts` as suspect in `marketId` on behalf of guardian `onBehalf`. Callable by `onBehalf` or its delegate. A suspect report never latches a ban; it raises the activation delay like a flag, but only while inside the suspect window. A non-zero `lastScannedBlock` hash also advances the guardian's heartbeat.

### `unsuspect`

```solidity
function unsuspect(
    Id marketId,
    address onBehalf,
    address[] calldata accounts
) external;
```

Retract guardian `onBehalf`'s suspect reports on `accounts` in `marketId`. Callable by `onBehalf` or its delegate. Per account a no-op when the guardian has no live report on it.

### `prune`

```solidity
function prune(Id marketId, address account) external;
```

Permissionless: prune `account`'s flags and suspect reports in `marketId` cast by guardians that were since removed, lowering the flag count. When any suspect report is pruned the active-suspect snapshot is re-taken, so the pruned reports stop counting toward the activation delay immediately. A latched ban is never lifted; after pruning, if the surviving current-committee flags still meet quorum the (quorum-derived) ban is latched, otherwise that still-unlatched ban lapses.

### `ban`

```solidity
function ban(Id marketId, address account) external;
```

Force a ban on `account` in `marketId`, bypassing the quorum.

### `unban`

```solidity
function unban(Id marketId, address account) external;
```

Lift the ban on `account` in `marketId` and clear its flags. Suspect reports are left intact (they carry no ban), so a suspect-driven delay survives the unban.

### `getFlaggedBy`

```solidity
function getFlaggedBy(
    Id marketId,
    address account
) external view returns (address[] memory);
```

The guardians currently flagging `account` in `marketId`.

### `getSuspectedBy`

```solidity
function getSuspectedBy(
    Id marketId,
    address account
) external view returns (address[] memory guardians, uint40[] memory reportedAt);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market to read the signal in. |
| `account` | `address` | The account to read. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `guardians` | `address[]` | The guardians currently reporting the account as suspect. |
| `reportedAt` | `uint40[]` | The timestamp of each guardian's last suspect report, aligned by index with `guardians`. |

The guardians with a live suspect report on `account` in `marketId`, paired with each report's timestamp.
