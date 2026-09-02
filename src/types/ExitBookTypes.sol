// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared value types of the exit book, defined at file scope (not in a library) so they import as
///         bare types.

// ---
// TYPES
// ---

/// @notice Lifecycle marker. `NotCreated` is the zero-value sentinel for unknown ids, not a stored request state.
///         `Expired` is not stored: it is derived from `block.timestamp > deadline`.
enum ExitStatus {
    NotCreated,
    Open,
    Filled,
    Cancelled
}

/// @notice Lender-set priority-fee schedule: the fee rate offered to fillers. The rate holds at `startRate`
///         for `rampStart` seconds from creation, then rises linearly to `endRate` by `rampEnd`, then holds at
///         `endRate` until the deadline. Rates are WAD fractions, each capped at `MAX_PRIORITY_FEE`.
/// @param startRate Priority-fee rate (WAD) charged from creation through the `rampStart` hold.
/// @param endRate Priority-fee rate (WAD) reached after the ramp and held to the deadline; `>= startRate`.
/// @param rampStart Seconds from creation the rate holds at `startRate` before the climb begins (0 climbs
///        immediately).
/// @param rampEnd Seconds from creation the climb reaches `endRate` (>= `rampStart`, equal means an instant jump).
struct PriorityRamp {
    uint256 startRate;
    uint256 endRate;
    uint256 rampStart;
    uint256 rampEnd;
}

/// @notice One exit request's source-agnostic lifecycle state. The backing source (which vault / which market)
///         lives in a per-id mapping outside this record. Remaining and total assets are stored as `uint128`.
/// @param owner The exiting lender whose position the fill withdraws from, and the only address that may cancel.
/// @param createdAt Creation timestamp: the fee schedule's start.
/// @param deadline Last timestamp the request may be filled. Chosen by the lender, capped at
///        `createdAt + MAX_REQUEST_LIFETIME` and never earlier than `createdAt + rampEnd`.
/// @param receiver Address credited the filled amount minus the priority fee.
/// @param status NotCreated for an unknown id; stored requests are Open / Filled / Cancelled (Expired is derived).
/// @param asset The underlying loan token paid out: the request, proceeds, and fees are denominated in it.
/// @param assetsRemaining Outstanding asset amount to exit.
/// @param assetsTotal Original asset amount requested.
/// @param minFillAssets Minimum non-final fill; 0 disables it. Whole-remainder fills qualify; capped at assetsTotal.
/// @param maxShareBurn Nominal full-request share budget. A fill may burn at most
///        `ceil(maxShareBurn * fillAssets / assetsTotal)`; across split fills, total burn may exceed this value by
///        at most one raw share unit per additional fill.
/// @param startRate Priority-fee rate (WAD) in force from `createdAt` through the `rampStart` hold.
/// @param endRate Priority-fee rate (WAD) reached at `createdAt + rampEnd` and held to the deadline.
/// @param rampStart Seconds from `createdAt` the rate holds at `startRate` before the climb begins.
/// @param rampEnd Seconds from `createdAt` the climb reaches `endRate`.
struct Request {
    address owner;
    uint40 createdAt;
    uint40 deadline;
    address receiver;
    ExitStatus status;
    IERC20 asset;
    uint128 assetsRemaining;
    uint128 assetsTotal;
    uint128 minFillAssets;
    uint128 maxShareBurn;
    uint96 startRate;
    uint96 endRate;
    uint32 rampStart;
    uint32 rampEnd;
}
