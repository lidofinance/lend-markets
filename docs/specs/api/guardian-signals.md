<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# GuardianSignals

Guardian-committee signal layer over accounts, keyed per market. Each committee seat is a *guardian* with a rotatable operator key and an immutable guardian key: the operator only raises signals (flag, suspect), the guardian also retracts them and rotates the operator key. A `quorum` of distinct guardians' flags latches a ban in the market it was raised in. The minimal read surface the market controller depends on (`getOpinion`, `isBanned`) is {IGuardianSignalsView}; this interface adds the full surface on top.

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
event GuardianAdded(address indexed guardian, address indexed operator);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `guardian` | `address` | The seat's immutable guardian key (its stable id). |
| `operator` | `address` | The guardian's rotatable operator key. |

Emitted when a guardian is added.

### `GuardianRemoved`

```solidity
event GuardianRemoved(address indexed guardian, address indexed operator);
```

Emitted when a guardian is removed.

### `OperatorRotated`

```solidity
event OperatorRotated(address indexed guardian, address indexed oldOperator, address indexed newOperator);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `guardian` | `address` | The guardian (its immutable guardian key). |
| `oldOperator` | `address` | The retired operator key. |
| `newOperator` | `address` | The new operator key. |

Emitted when a guardian rotates its operator key.

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
| `guardian` | `address` | The seat (by guardian key) that reported. |
| `blockNumber` | `uint40` | The block number the guardian reports scanning past (carried for off-chain tooling). |
| `timestamp` | `uint40` | The reported block's timestamp; the quorum-scan frontier orders guardians by this value. |

Emitted when a guardian reports liveness, directly or via `flag`/`suspect`.

### `Suspected`

```solidity
event Suspected(Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 timestamp);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market the report is scoped to. |
| `account` | `address` | The suspected account. |
| `guardian` | `address` | The reporting seat (by guardian key). |
| `actor` | `address` | The key that made the call (the operator, or the guardian itself). |
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
| `guardian` | `address` | The flagging seat (by guardian key). |
| `actor` | `address` | The key that made the call (the operator, or the guardian itself). |
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
| `marketId` | `Id` |  |
| `account` | `address` |  |
| `by` | `address` | The `ACCESS_RESTORER_ROLE` holder that unbanned. |

Emitted when an account's ban is lifted.

## Errors

### `ZeroAddress`

```solidity
error ZeroAddress();
```

Thrown when a zero address is passed where an account, guardian or operator is required.

### `InvalidParams`

```solidity
error InvalidParams();
```

Thrown on malformed input: mismatched guardian/operator arrays, or a guardian equal to its operator.

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

Thrown when an address already fills a guardian or operator role.

### `NotOperator`

```solidity
error NotOperator();
```

Thrown when a signal is raised by a caller that is neither a guardian nor an operator.

### `NotGuardian`

```solidity
error NotGuardian();
```

Thrown when a guardian-only action is called by a non-guardian (an operator key is not a guardian).

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
function addGuardian(address guardian, address operator) external;
```

Add a guardian: an immutable guardian key paired with a rotatable operator key. Both must be non-zero, distinct, and not already fill a guardian or operator role.

### `removeGuardian`

```solidity
function removeGuardian(address guardian) external;
```

Remove the guardian `guardian`.

### `rotateOperator`

```solidity
function rotateOperator(address newOperator) external;
```

Rotate the caller-guardian's operator key to `newOperator`. Guardian-only. Keeps the guardian's flags, suspect reports and heartbeat, since those are keyed by the immutable guardian id.

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

### `isOperator`

```solidity
function isOperator(address account) external view returns (bool);
```

Whether `account` is a current operator key.

### `isGuardian`

```solidity
function isGuardian(address account) external view returns (bool);
```

Whether `account` is a guardian.

### `guardianOf`

```solidity
function guardianOf(address operator) external view returns (address);
```

The guardian of operator key `operator`, or zero if it is not an operator.

### `operatorOf`

```solidity
function operatorOf(address guardian) external view returns (address);
```

The current operator key of guardian `guardian`, or zero if `guardian` is not a guardian.

### `getGuardianCount`

```solidity
function getGuardianCount() external view returns (uint256);
```

The number of guardians.

### `getGuardians`

```solidity
function getGuardians() external view returns (address[] memory);
```

The guardian keys, one per seat.

### `getOperators`

```solidity
function getOperators() external view returns (address[] memory);
```

The current operator keys, one per guardian.

### `heartbeat`

```solidity
function heartbeat(BlockInfoWithHash calldata lastScannedBlock) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `lastScannedBlock` | `BlockInfoWithHash` | The block the caller reports scanning past. |

Record the caller's last-scanned block, validated against its block hash and timestamp. Operator-only (only the operator key reports a scan); the record is keyed by the seat's guardian so it survives an operator-key rotation. The quorum frontier is recomputed separately by `syncQuorumBlock`.

### `syncQuorumBlock`

```solidity
function syncQuorumBlock() external;
```

Recompute the quorum-scan frontier from current heartbeats and ratchet it up. Permissionless and monotonic.

### `getHeartbeat`

```solidity
function getHeartbeat(address account) external view returns (uint40 timestamp);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `timestamp` | `uint40` | The last-scanned block timestamp. |

The Unix timestamp of the last block `account`'s guardian reported scanning (0 if never, or not a guardian/operator). `account` may be either the operator or the guardian key.

### `getHeartbeats`

```solidity
function getHeartbeats() external view returns (address[] memory operators, uint40[] memory timestamps);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `operators` | `address[]` | The current operator keys. |
| `timestamps` | `uint40[]` | Each guardian's last-scanned block timestamp, aligned by index with `operators`. |

The current operator keys paired with each guardian's last-scanned block timestamp.

### `getQuorumFrontier`

```solidity
function getQuorumFrontier() external view returns (uint40);
```

Highest block timestamp at least a quorum of guardians have ever scanned past. Monotonic.

### `flag`

```solidity
function flag(
    Id marketId,
    address[] calldata accounts,
    BlockInfoWithHash calldata lastScannedBlock
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market to flag in. |
| `accounts` | `address[]` | The accounts to flag. |
| `lastScannedBlock` | `BlockInfoWithHash` | The operator's heartbeat, validated like `heartbeat`; ignored when a guardian calls. |

Flag `accounts` in `marketId`. Callable by the seat's operator or its guardian; both write the same seat, so an operator and its guardian flagging one account count as a single strike. Per account a no-op when the seat already flags it, so a batch never reverts on a skip. When the caller is the operator, `lastScannedBlock` also advances the seat's heartbeat; a guardian flagging does not.

### `unflag`

```solidity
function unflag(Id marketId, address[] calldata accounts) external;
```

Retract the seat's flags on `accounts` in `marketId`. Guardian-only. Per account a no-op when the seat does not flag it. Never lifts a latched ban.

### `suspect`

```solidity
function suspect(
    Id marketId,
    address[] calldata accounts,
    BlockInfoWithHash calldata lastScannedBlock
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` |  |
| `accounts` | `address[]` |  |
| `lastScannedBlock` | `BlockInfoWithHash` | The operator's heartbeat, validated like `heartbeat`; ignored when a guardian calls. |

Report `accounts` as suspect in `marketId`. Callable by the seat's operator or its guardian. A suspect report never latches a ban; it raises the activation delay like a flag, but only while inside the suspect window. When the caller is the operator, `lastScannedBlock` also advances the seat's heartbeat.

### `unsuspect`

```solidity
function unsuspect(Id marketId, address[] calldata accounts) external;
```

Retract the seat's suspect reports on `accounts` in `marketId`. Guardian-only. Per account a no-op when the seat has no live report on it.

### `prune`

```solidity
function prune(Id marketId, address account) external;
```

Permissionless: prune `account`'s flags and suspect reports in `marketId` cast by guardians that were since removed, lowering the flag count. The pruned suspect reports leave the set, but the cached suspect count the activation delay reads is re-derived only on the next `suspect`/`unsuspect`, not here — so a pruned report keeps counting toward the delay until then. Never changes ban status.

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

The seats (by guardian key) currently flagging `account` in `marketId`.

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
| `guardians` | `address[]` | The seats (by guardian key) currently reporting the account as suspect. |
| `reportedAt` | `uint40[]` | The timestamp of each guardian's last suspect report, aligned by index with `guardians`. |

The guardians with a live suspect report on `account` in `marketId`, paired with each report's timestamp.
