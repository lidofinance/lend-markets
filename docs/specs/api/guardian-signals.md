<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# GuardianSignals

Guardian-committee signal layer over accounts, keyed per market. Guardians flag accounts they detect as malicious. A `quorum` of distinct flags latches a ban in the market it was raised in. The minimal read surface the market controller depends on (`getOpinion`, `isBanned`) is {IGuardianSignalsView}; this interface adds the full guardian/committee/governance surface on top.

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

Emitted when a guardian joins the set.

### `GuardianRemoved`

```solidity
event GuardianRemoved(address indexed guardian);
```

Emitted when a guardian leaves the set.

### `QuorumSet`

```solidity
event QuorumSet(uint256 quorum);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `quorum` | `uint256` | The number of distinct flags that latches a ban. |

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
| `guardian` | `address` | The guardian that reported. |
| `blockNumber` | `uint40` | The block number the guardian reports scanning past (carried for off-chain tooling). |
| `timestamp` | `uint40` | The reported block's timestamp; the quorum-scan frontier orders guardians by this value. |

Emitted when a guardian reports liveness, directly or via `flag`/`unflag`.

### `Suspected`

```solidity
event Suspected(Id indexed marketId, address indexed account, address indexed guardian, uint256 timestamp);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market the report is scoped to. |
| `account` | `address` | The suspected account. |
| `guardian` | `address` | The reporting guardian. |
| `timestamp` | `uint256` | The report time, recorded so the report can be aged out of the suspect window. |

Emitted when a guardian reports an account as suspect (raises the activation delay, never bans).

### `SuspectCleared`

```solidity
event SuspectCleared(Id indexed marketId, address indexed account, address indexed guardian);
```

Emitted when a guardian retracts its suspect report on an account.

### `SuspectPruned`

```solidity
event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);
```

Emitted when a suspect report cast by an address that is no longer a guardian is pruned.

### `Flagged`

```solidity
event Flagged(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id. |
| `account` | `address` | The flagged account. |
| `guardian` | `address` | The flagging guardian. |
| `strikes` | `uint16` | The account's flag count after the flag. |

Emitted when a guardian flags an account.

### `Unflagged`

```solidity
event Unflagged(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
```

Emitted when a guardian retracts a flag.

### `FlagPruned`

```solidity
event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
```

Emitted when a flag cast by an address that is no longer a guardian is pruned.

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

Thrown when adding a guardian already in the set.

### `NotGuardian`

```solidity
error NotGuardian();
```

Thrown when the caller or target is not a guardian.

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `guardian` | `address` | The address to add. Must be non-zero, not already a guardian, and within `MAX_GUARDIANS_COUNT`. |

Add a guardian to the set.

### `removeGuardian`

```solidity
function removeGuardian(address guardian) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `guardian` | `address` | The guardian to remove. Reverts if not currently a guardian. |

Remove a guardian from the set. Reverts if it would drop the set below the quorum.

### `setQuorum`

```solidity
function setQuorum(uint256 newQuorum) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `newQuorum` | `uint256` | The new quorum. |

Set the quorum — the distinct flags that latch a ban. Reverts if zero or above the guardian count.

### `setSuspectWindow`

```solidity
function setSuspectWindow(uint256 suspectWindow) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `suspectWindow` | `uint256` | The new suspect window. |

Set the suspect window — the freshness horizon within which a suspect report still counts. Reverts if it exceeds `MAX_SUSPECT_WINDOW`. Never touches the guardian set. The per-flag and per-suspect delays live in the market's activation config, not here.

### `getQuorum`

```solidity
function getQuorum() external view returns (uint256);
```

The quorum: distinct flags that latch a ban.

### `getSuspectWindow`

```solidity
function getSuspectWindow() external view returns (uint256);
```

The suspect window: the freshness horizon within which a suspect report still counts.

### `isGuardian`

```solidity
function isGuardian(address account) external view returns (bool);
```

Whether `account` is a guardian.

### `getGuardianCount`

```solidity
function getGuardianCount() external view returns (uint256);
```

The number of guardians in the set.

### `getGuardians`

```solidity
function getGuardians() external view returns (address[] memory);
```

The current guardian set.

### `heartbeat`

```solidity
function heartbeat(BlockInfoWithHash calldata lastScannedBlock) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `lastScannedBlock` | `BlockInfoWithHash` | The block the caller reports scanning past. Reverts if `number` exceeds the current block, if `hash` does not match `blockhash(number)`, if `timestamp` exceeds the current block, or if `timestamp` is below the caller's previous heartbeat. |

Record the caller's last-scanned block, validated against its block hash and timestamp. The quorum frontier is recomputed separately by `syncQuorumBlock`. Caller must be a guardian.

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

The Unix timestamp of the last block `guardian` reported scanning (0 if it never has).

### `getHeartbeats`

```solidity
function getHeartbeats() external view returns (address[] memory guardians, uint40[] memory timestamps);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `guardians` | `address[]` | The guardian set. |
| `timestamps` | `uint40[]` | Each guardian's last-scanned block timestamp, aligned by index with `guardians`. |

The guardian set paired with each guardian's last-scanned block timestamp.

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
| `accounts` | `address[]` | The accounts to flag. A zero address in the batch reverts. |
| `lastScannedBlock` | `BlockInfoWithHash` | The heartbeat recorded for the caller after flagging, validated like `heartbeat`. |

Flag `accounts` in `marketId`, then heartbeat. Per account a no-op when the caller already flags it, so a batch never reverts on a skip.

### `unflag`

```solidity
function unflag(
    Id marketId,
    address[] calldata accounts,
    BlockInfoWithHash calldata lastScannedBlock
) external;
```

Retract the caller's flags on `accounts` in `marketId`, then heartbeat. Per account a no-op when the caller does not flag it. Never lifts a latched ban.

### `suspect`

```solidity
function suspect(
    Id marketId,
    address[] calldata accounts,
    BlockInfoWithHash calldata lastScannedBlock
) external;
```

Report `accounts` as suspect in `marketId`, then heartbeat. A suspect report never latches a ban; it raises the activation delay like a flag, but only while inside the suspect window. A zero address in the batch reverts.

### `unsuspect`

```solidity
function unsuspect(
    Id marketId,
    address[] calldata accounts,
    BlockInfoWithHash calldata lastScannedBlock
) external;
```

Retract the caller's suspect reports on `accounts` in `marketId`, then heartbeat. Per account a no-op when the caller has no live report on it.

### `prune`

```solidity
function prune(Id marketId, address account) external;
```

Permissionless: prune `account`'s flags and suspect reports in `marketId` cast by addresses that are no longer guardians, lowering the flag count. The pruned suspect reports leave the set, but the cached suspect count the activation delay reads is re-derived only on the next `suspect`/`unsuspect`, not here — so a pruned report keeps counting toward the delay until then. Never changes ban status.

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
| `guardians` | `address[]` | The addresses of guardians currently reporting the account as suspect. |
| `reportedAt` | `uint40[]` | The timestamp of each guardian's last suspect report, aligned by index with `guardians`. |

The guardians with a live suspect report on `account` in `marketId`, paired with each report's timestamp.
