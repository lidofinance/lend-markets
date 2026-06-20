// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice An account's latched guardian status. `Normal` is clean. `Immune` exempts the account from
///         guardian signals. `Banned` hard-blocks borrowing, latched by a quorum of flags or a forced `ban`.
enum Status {
    Normal,
    Immune,
    Banned
}

/// @notice A scanned block recorded by a guardian heartbeat.
/// @param number    The block number.
/// @param timestamp The block timestamp, carried so readers can gate on time without a second lookup.
struct BlockInfo {
    uint40 number;
    uint40 timestamp;
}

/// @notice Heartbeat payload: a scanned block plus its hash, validated against `blockhash(number)` before
///         the registry records it as a `BlockInfo`.
/// @param hash      The reported block hash, checked against `blockhash(number)`.
/// @param number    The block number, which may not exceed the current block.
/// @param timestamp The block timestamp.
struct BlockInfoWithHash {
    bytes32 hash;
    uint40 number;
    uint40 timestamp;
}

/// @notice Per-account guardian signal, stored per `(market, account)`.
/// @param status    Latched status. A quorum of flags or a forced `ban` latches `Banned`, held until `unban`.
///        While `Immune`, `flag`/`unflag` no-op and readers see the account as clean.
/// @param flaggedBy Live set of guardians currently flagging the account. Its size is the strike count, and
///        `unban` clears it in one call.
struct GuardiansSignal {
    Status status;
    EnumerableSet.AddressSet flaggedBy;
}

/// @notice Read model of an account's signal, returned by `getOpinion` and consumed by the controller's
///         activation gate.
/// @param status     The account's latched status.
/// @param strikes     The current flag count. Below quorum it scales the activation delay up.
/// @param quorumBlock The quorum-scan frontier: the highest block a quorum of guardians have scanned past.
struct GuardiansOpinion {
    Status status;
    uint256 strikes;
    BlockInfo quorumBlock;
}
