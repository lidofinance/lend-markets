<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# GuardianSignals

Guardian-committee signal layer over accounts, keyed per market. Guardians flag accounts they detect as malicious. A `quorum` of distinct flags latches a ban. The market controller reads `getOpinion` to scale collateral activation and to hard-block borrowing.

## Enums

### `Status`

```solidity
enum Status {
    Normal,
    Immune,
    Banned
}
```

An account's latched guardian status. `Normal` is clean. `Immune` exempts the account from guardian signals. `Banned` hard-blocks borrowing, latched by a quorum of flags or a forced `ban`.

## Structs

### `BlockInfo`

```solidity
struct BlockInfo {
    uint40 number;
    uint40 timestamp;
}
```

A scanned block recorded by a guardian heartbeat.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `number` | `uint40` | The block number. |
| `timestamp` | `uint40` | The block timestamp, carried so readers can gate on time without a second lookup. |

### `BlockInfoWithHash`

```solidity
struct BlockInfoWithHash {
    bytes32 hash;
    uint40 number;
    uint40 timestamp;
}
```

Heartbeat payload: a scanned block plus its hash, validated against `blockhash(number)` before the registry records it as a `BlockInfo`.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `hash` | `bytes32` | The reported block hash, checked against `blockhash(number)`. |
| `number` | `uint40` | The block number, which may not exceed the current block. |
| `timestamp` | `uint40` | The block timestamp. |

### `GuardiansOpinion`

```solidity
struct GuardiansOpinion {
    Status status;
    uint256 strikes;
    uint256 flagCount;
    BlockInfo quorumBlock;
}
```

Read model of an account's signal, returned by `getOpinion` and consumed by the controller's activation gate.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `status` | `Status` | The account's latched status. |
| `strikes` | `uint256` | Effective guardian strikes: the flag count that scales the activation delay, forced to 0 while `Immune` so an exempt account carries no surcharge. |
| `flagCount` | `uint256` | Raw number of guardians currently flagging the account, regardless of status. Equals `strikes` except while `Immune`, where it stays visible while `strikes` reads 0. |
| `quorumBlock` | `BlockInfo` | The quorum-scan frontier: the highest block a quorum of guardians have scanned past. |

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

### `Heartbeat`

```solidity
event Heartbeat(address indexed guardian);
```

Emitted when a guardian reports liveness, directly or via `flag`/`unflag`.

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id. |
| `account` | `address` | The account. |
| `guardian` | `address` | The retracting guardian. |
| `strikes` | `uint16` | The account's flag count after the retraction. |

Emitted when a guardian retracts a flag.

### `FlagPruned`

```solidity
event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id. |
| `account` | `address` | The account. |
| `guardian` | `address` | The former guardian whose flag was pruned. |
| `strikes` | `uint16` | The account's flag count after this flag was pruned. |

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

### `ImmunityGranted`

```solidity
event ImmunityGranted(Id indexed marketId, address indexed account, address indexed by);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` |  |
| `account` | `address` |  |
| `by` | `address` | The `ACCESS_RESTORER_ROLE` holder that granted immunity. |

Emitted when an account is exempted.

### `ImmunityRevoked`

```solidity
event ImmunityRevoked(Id indexed marketId, address indexed account, address indexed by);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` |  |
| `account` | `address` |  |
| `by` | `address` | The `ACCESS_LIMITER_ROLE` holder that revoked immunity. |

Emitted when an account's immunity is removed.

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

### `InvalidBlockHash`

```solidity
error InvalidBlockHash();
```

Thrown when a heartbeat's reported hash does not match the block's hash.

## Functions

### `getQuorum`

```solidity
function getQuorum() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | The current quorum. |

The number of distinct flags that latches a ban.

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
| `newQuorum` | `uint256` | The new number of distinct flags that latches a ban. |

Set the quorum. Reverts unless `1 <= newQuorum <= guardian count`.

### `isGuardian`

```solidity
function isGuardian(address account) external view returns (bool);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `account` | `address` | The address to check. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bool` | True if `account` is in the guardian set. |

Whether `account` is a guardian.

### `getGuardianCount`

```solidity
function getGuardianCount() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | The guardian count. |

The number of guardians in the set.

### `getGuardians`

```solidity
function getGuardians() external view returns (address[] memory);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `address[]` | The list of guardian addresses. |

The current guardian set.

### `heartbeat`

```solidity
function heartbeat(BlockInfoWithHash calldata lastScannedBlock) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `lastScannedBlock` | `BlockInfoWithHash` | The block the caller reports scanning past. Reverts if `number` exceeds the current block or if `hash` does not match `blockhash(number)`. Only the caller (a guardian) is recorded. |

Record the caller's last-scanned block, validated against its block hash. O(1): the quorum frontier is recomputed separately by `syncQuorumBlock`.

### `syncQuorumBlock`

```solidity
function syncQuorumBlock() external;
```

Recompute the quorum-scan frontier from current heartbeats and ratchet it up. Permissionless and monotonic — anyone may advance it (an off-chain agent per scan frame, or a borrower whose activation depends on it). Decoupled from `heartbeat` so heartbeats stay O(1).

### `getHeartbeat`

```solidity
function getHeartbeat(
    address guardian
) external view returns (BlockInfo memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `guardian` | `address` | The guardian to query. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `BlockInfo` | The guardian's last-scanned block. Zero-valued if the guardian has never reported a heartbeat. |

The last block `guardian` reported scanning.

### `getHeartbeats`

```solidity
function getHeartbeats() external view returns (address[] memory guardians, BlockInfo[] memory heartbeats);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `guardians` | `address[]` | The current guardian set. |
| `heartbeats` | `BlockInfo[]` | The last-scanned block of each guardian, aligned by index with `guardians`. |

The guardian set paired with each guardian's last-scanned block.

### `getLastScannedQuorumBlock`

```solidity
function getLastScannedQuorumBlock() external view returns (BlockInfo memory);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `BlockInfo` | The quorum-scan frontier as last ratcheted by `syncQuorumBlock`. |

Highest block at least a quorum of guardians have ever scanned past. Monotonic: a guardian rotation cannot lower it.

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
| `marketId` | `Id` | The market id the accounts are flagged in. |
| `accounts` | `address[]` | The accounts to flag. A zero address in the batch reverts. Each one a no-op when already flagged by the caller or immune. |
| `lastScannedBlock` | `BlockInfoWithHash` | The heartbeat recorded for the caller after flagging, validated like `heartbeat`. |

Flag `accounts` in `marketId`, then heartbeat. Per account a no-op when the caller already flags it or it is immune, so a batch never reverts on a skip.

### `unflag`

```solidity
function unflag(
    Id marketId,
    address[] calldata accounts,
    BlockInfoWithHash calldata lastScannedBlock
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id the flags are retracted in. |
| `accounts` | `address[]` | The accounts to unflag. Each one a no-op when not flagged by the caller or immune. |
| `lastScannedBlock` | `BlockInfoWithHash` | The heartbeat recorded for the caller after retracting, validated like `heartbeat`. |

Retract the caller's flags on `accounts` in `marketId`, then heartbeat. Per account a no-op when the caller does not flag it or it is immune. Never lifts a latched ban.

### `prune`

```solidity
function prune(Id marketId, address account) external;
```

Permissionless: prune `account`'s flags cast by addresses that are no longer guardians. Lowers the flag count (and, below quorum, the activation surcharge) but never changes status — a latched ban lifts only through `unban`, so this is not a permissionless unban.

### `ban`

```solidity
function ban(Id marketId, address account) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id the ban applies in. |
| `account` | `address` | The account to ban. Reverts on the zero address. |

Force a ban on `account` in `marketId`, bypassing the quorum. Clears any immunity.

### `unban`

```solidity
function unban(Id marketId, address account) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id the ban is lifted in. |
| `account` | `address` | The account to unban. Its status returns to `Normal` and its flagger set is cleared. |

Lift the ban on `account` in `marketId`: reset its status to `Normal` and clear its flags, so guardians re-evaluate from scratch and can re-ban it. Resetting to `Normal` also clears a standing immunity, so manage immunity with `grantImmunity` / `revokeImmunity`.

### `grantImmunity`

```solidity
function grantImmunity(Id marketId, address account) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id the immunity applies in. |
| `account` | `address` | The account to exempt. Reverts on the zero address. Its status is set to `Immune`. |

Exempt `account` in `marketId` from guardian signals. While immune, `flag`/`unflag` no-op and `getOpinion` reads it as clean. Cleared by `revokeImmunity` or `ban`.

### `revokeImmunity`

```solidity
function revokeImmunity(Id marketId, address account) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id the immunity is revoked in. |
| `account` | `address` | The account whose immunity is removed. Its status returns to `Normal`. |

Remove `account`'s immunity in `marketId`, re-subjecting it to guardian signals.

### `getOpinion`

```solidity
function getOpinion(
    Id marketId,
    address account
) external view returns (GuardiansOpinion memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id to read. |
| `account` | `address` | The account to read. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `GuardiansOpinion` | The opinion: latched status, effective strikes (forced to 0 while `Immune`), raw flag count, and the quorum-scan frontier. |

Guardian opinion on `account` in `marketId`: status, strike count, and the quorum-scan frontier. The view the controller's activation gate consumes.

### `getFlaggedBy`

```solidity
function getFlaggedBy(
    Id marketId,
    address account
) external view returns (address[] memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id to read. |
| `account` | `address` | The account to read. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `address[]` | The addresses of guardians currently flagging the account. |

The guardians currently flagging `account` in `marketId`.
