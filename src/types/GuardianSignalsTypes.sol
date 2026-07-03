// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// ---
// TYPES
// ---

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
/// @param banned           Latched ban. A quorum of flags or a forced `ban` sets it, held until `unban`.
/// @param suspectReportedAt Timestamp of the last suspect report or retraction. Anchors the suspect snapshot.
/// @param suspectCount     Active suspect reports at `suspectReportedAt`. Snapshotted on report/retraction so the
///        activation delay need not re-scan the suspect set: the suspect surcharge is
///        `suspectCount * delayPerSuspect`, applied while `now - suspectReportedAt <= that`, then it lapses to 0.
/// @param flaggedBy        Live set of guardians currently flagging the account. Its size is the raw flag count,
///        which is the effective strikes. `unban` clears it in one call.
/// @param suspectedBy      Live set of guardians who reported the account as suspect. Unlike a flag, a suspect
///        report never latches a ban; it scales the activation delay like a strike, but only while fresh —
///        counted only when its `suspectedAt` timestamp falls inside the market's suspect window.
/// @param suspectedAt      Per-guardian timestamp of the last suspect report, kept so stale reports can be excluded.
struct GuardiansSignal {
    bool banned;
    uint40 suspectReportedAt;
    uint16 suspectCount;
    EnumerableSet.AddressSet flaggedBy;
    EnumerableSet.AddressSet suspectedBy;
    mapping(address guardian => uint40 timestamp) suspectedAt;
}

/// @notice Everything the controller reads about an account in one call, forwarded to the activation lib which
///         owns the delay math. Returned by `getOpinion`.
/// @param banned                  Whether the account is banned (hard-blocks borrowing).
/// @param strikeCount             Raw guardian flags on the account.
/// @param suspectCount            Active suspect reports snapshotted at the last report/retraction.
/// @param suspectExpiryTimestamp  When the current suspect snapshot lapses (`suspectReportedAt + suspectWindow`);
///        the activation lib applies the suspect surcharge only to lots whose activation started before this.
/// @param quorumFrontierTimestamp The quorum-scan frontier timestamp.
struct GuardiansOpinion {
    bool banned;
    uint256 strikeCount;
    uint256 suspectCount;
    uint256 suspectExpiryTimestamp;
    uint256 quorumFrontierTimestamp;
}
