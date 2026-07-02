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

/// @notice Full per-market guardian configuration, set (and read) in one shot via `setMarketConfig` /
///         `getMarketConfig`.
/// @param guardians       The market's guardian set. Each must be non-zero, unique, and within `MAX_GUARDIANS_COUNT`.
/// @param quorum          Distinct flags that latch a ban. Must satisfy `1 <= quorum <= guardians.length`.
/// @param delayPerStrike  Activation-delay surcharge per flag. Must not exceed `MAX_DELAY_PER_STRIKE`.
/// @param delayPerSuspect Activation-delay surcharge per fresh suspect report. Must not exceed `MAX_DELAY_PER_STRIKE`.
/// @param maxDelay        Cap on the total guardian activation-delay surcharge (flags + suspects). 0 means uncapped.
/// @param suspectWindow   Freshness horizon within which a suspect report still counts. Must not exceed
///        `MAX_SUSPECT_WINDOW`.
struct GuardianConfig {
    address[] guardians;
    uint256 quorum;
    uint256 delayPerStrike;
    uint256 delayPerSuspect;
    uint256 maxDelay;
    uint256 suspectWindow;
}

/// @notice Everything the controller reads about an account in one call: the ban gate plus the activation-gate
///         inputs. Returned by `getAccountSignals`.
/// @param banned              Whether the account is banned (hard-blocks borrowing).
/// @param flagCount           Raw number of guardians currently flagging the account.
/// @param activationDelay     The activation-delay surcharge (`type(uint256).max` when banned, 0 when immune).
/// @param quorumBlockTimestamp The market's quorum-scan frontier timestamp.
struct AccountSignals {
    bool banned;
    uint256 flagCount;
    uint256 activationDelay;
    uint256 quorumBlockTimestamp;
}

/// @notice Read model of an account's signal, returned by `getOpinion` and consumed by the controller's
///         activation gate.
/// @param status     The account's latched status.
/// @param strikes     Effective guardian strikes: the flag count that scales the activation delay, forced to 0
///        while `Immune` so an exempt account carries no surcharge.
/// @param flagCount   Raw number of guardians currently flagging the account, regardless of status. Equals
///        `strikes` except while `Immune`, where it stays visible while `strikes` reads 0.
/// @param quorumFrontierTimestamp The quorum-scan frontier: the highest timestamp a quorum of guardians have
///        scanned past.
struct GuardiansOpinion {
    Status status;
    uint256 strikes;
    uint256 flagCount;
    uint256 quorumFrontierTimestamp;
}
