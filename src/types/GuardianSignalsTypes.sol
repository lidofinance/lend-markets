// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// ---
// TYPES
// ---

/// @notice An account's latched guardian status. `Normal` is clean. `Immune` exempts the account from
///         guardian signals. `Banned` hard-blocks borrowing, latched by a quorum of flags or a forced `ban`.
enum Status {
    Normal,
    Immune,
    Banned
}

/// @notice Heartbeat payload: a scanned block plus its hash, validated against `blockhash(number)`. Only the
///         `timestamp` is kept in storage (the frontier gates on time); `number` + `hash` prove the block is
///         real and un-reorged, and `number` is re-emitted in the `Heartbeat` event for off-chain tooling.
/// @param hash      The reported block hash, checked against `blockhash(number)`.
/// @param number    The block number, which may not exceed the current block.
/// @param timestamp The block timestamp.
struct BlockInfoWithHash {
    bytes32 hash;
    uint40 number;
    uint40 timestamp;
}

/// @notice Per-account guardian signal, stored per `(market, account)`.
/// @param status      Latched status. A quorum of flags or a forced `ban` latches `Banned`, held until `unban`.
///        While `Immune`, `flag`/`unflag` no-op and readers see the account as clean.
/// @param flaggedBy   Live set of guardians currently flagging the account. Its size is the raw flag count,
///        which becomes the effective strikes unless the account is `Immune`. `unban` clears it in one call.
/// @param suspectedBy Live set of guardians who reported the account as suspect. Unlike a flag, a suspect
///        report never latches a ban; it scales the activation delay like a strike, but only while fresh —
///        counted only when its `suspectedAt` timestamp falls inside the market's suspect window.
/// @param suspectedAt Per-guardian timestamp of the last suspect report, kept so stale reports can be excluded.
struct GuardiansSignal {
    Status status;
    EnumerableSet.AddressSet flaggedBy;
    EnumerableSet.AddressSet suspectedBy;
    mapping(address guardian => uint40 timestamp) suspectedAt;
}

/// @notice The guardian activation-delay parameters, set (and read) in one shot via `setDelayParams` /
///         `getDelayParams`.
/// @param delayPerStrike  Activation-delay surcharge per flag. Must not exceed `MAX_DELAY_PER_STRIKE`.
/// @param delayPerSuspect Activation-delay surcharge per fresh suspect report. Must not exceed
///        `MAX_DELAY_PER_STRIKE`; inert while `suspectWindow` is 0, since a report is then fresh only in its
///        own block.
/// @param maxDelay        Cap on the total guardian activation-delay surcharge (flags + suspects). 0 = uncapped.
/// @param suspectWindow   Freshness horizon within which a suspect report still counts. Must not exceed
///        `MAX_SUSPECT_WINDOW`.
struct DelayParams {
    uint256 delayPerStrike;
    uint256 delayPerSuspect;
    uint256 maxDelay;
    uint256 suspectWindow;
}

/// @notice Everything the controller reads about an account in one call: the ban gate plus the activation-gate
///         inputs. Returned by `getOpinion`.
/// @param banned              Whether the account is banned (hard-blocks borrowing).
/// @param activationDelay     The activation-delay surcharge (`type(uint256).max` when banned, 0 when immune).
/// @param quorumFrontierTimestamp The quorum-scan frontier timestamp.
struct GuardiansOpinion {
    bool banned;
    uint256 activationDelay;
    uint256 quorumFrontierTimestamp;
}
