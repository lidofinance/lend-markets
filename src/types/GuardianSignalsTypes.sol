// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// ---
// TYPES
// ---

/// @notice Heartbeat payload: a scanned block identity plus a guardian-reported scan timestamp. `number` + `hash`
///         are validated against `blockhash(number)`; they do not attest the timestamp. Only the timestamp is kept
///         in storage for the frontier, while the block number is re-emitted for off-chain tooling.
/// @param hash The reported block hash, checked against `blockhash(number)`.
/// @param number The block number, which may not exceed the current block.
/// @param timestamp Guardian-reported scan timestamp. It must not exceed `block.timestamp` and cannot regress for
///        that guardian, but it is not checked against the reported block header.
struct BlockInfoWithHash {
    bytes32 hash;
    uint40 number;
    uint40 timestamp;
}

/// @notice Per-account guardian signal, stored per `(market, account)`.
/// @param banned Latched ban. A quorum of flags or a forced `ban` sets it, held until `unban`.
/// @param suspectReportedAt Timestamp of the latest active suspect report. Anchors the suspect snapshot.
/// @param suspectCount Active suspect reports at `suspectReportedAt`, snapshotted on report/retraction so the
///        delay needn't re-scan. The surcharge `suspectCount * delayPerSuspect` applies to a lot whose activation
///        began before the snapshot lapses (`suspectReportedAt + suspectWindow`).
/// @param flaggedBy Raw stored set of guardians flagging the account; removed guardians remain until pruning,
///        and `unban` clears the set.
/// @param suspectedBy Raw stored set of suspect reporters; removed guardians and expired reports remain until
///        their cleanup paths run. A suspect report never bans.
/// @param suspectedAt Per-guardian timestamp of the last suspect report, kept so stale reports can be excluded.
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
/// @param banned Whether the account is banned (hard-blocks borrowing).
/// @param strikeCount Raw guardian flags on the account.
/// @param suspectCount Active suspect reports snapshotted at the last report/retraction.
/// @param suspectExpiryTimestamp When the current suspect snapshot lapses (`suspectReportedAt + suspectWindow`);
///        the activation lib applies the suspect surcharge only to lots whose activation started before this.
/// @param quorumFrontierTimestamp The quorum-scan frontier timestamp.
struct GuardiansOpinion {
    bool banned;
    uint256 strikeCount;
    uint256 suspectCount;
    uint256 suspectExpiryTimestamp;
    uint256 quorumFrontierTimestamp;
}
