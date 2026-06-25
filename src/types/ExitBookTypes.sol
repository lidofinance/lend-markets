// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared value types of the exit book. File-scope so `ExitBookBase`, its concrete books, and
///         `IExitBook` use them as bare `Request` / `ExitStatus`.

/// @notice Lifecycle marker. `Expired` is not stored — it is derived from `block.timestamp > deadline`.
enum ExitStatus {
    Open,
    Filled,
    Cancelled
}

/// @notice Lender-set priority-fee schedule — a Dutch auction on the fee carved out of the amount owed. The rate
///         holds at `startRate` for `rampStart` seconds from creation, then climbs linearly to `endRate` by
///         `rampEnd`, then holds at `endRate` until the deadline. Rates are WAD fractions, each capped at
///         `MAX_PRIORITY_FEE`.
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

/// @notice One exit request — lifecycle and pricing only. The backing source (which vault / which market)
///         lives in the concrete book's per-id mappings, not here, so this struct is source-agnostic. Shares
///         and the price snapshot are `uint128` (capped via SafeCast at creation) so the record packs tighter.
/// @param owner The exiting lender, credited the proceeds and the only address that may cancel.
/// @param asset The underlying loan token paid out — proceeds and fees are denominated in it.
/// @param sizeRemaining Outstanding shares to fill. The fixed-price amount owed is `sizeRemaining * pricePerShare`.
/// @param sizeTotal Original shares at creation (informational).
/// @param pricePerShare Assets per share (WAD), snapshotted at creation; yield above it is the filler's.
/// @param startRate Priority-fee rate (WAD) in force from `createdAt` through the `rampStart` hold.
/// @param endRate Priority-fee rate (WAD) reached at `createdAt + rampEnd` and held to the deadline.
/// @param rampStart Seconds from `createdAt` the rate holds at `startRate` before the climb begins.
/// @param rampEnd Seconds from `createdAt` the climb reaches `endRate`.
/// @param createdAt Creation timestamp: the fee schedule's start.
/// @param deadline Last timestamp the request may be filled. Chosen by the lender, capped at
///        `createdAt + MAX_LIFETIME` and never earlier than `createdAt + rampEnd`.
/// @param fullFillOnly When true a fill must cover the whole remaining size in one shot or be rejected.
/// @param status Open / Filled / Cancelled (Expired is derived).
struct Request {
    address owner;
    IERC20 asset;
    uint128 sizeRemaining;
    uint128 sizeTotal;
    uint128 pricePerShare;
    uint96 startRate;
    uint96 endRate;
    uint32 rampStart;
    uint32 rampEnd;
    uint40 createdAt;
    uint40 deadline;
    bool fullFillOnly;
    ExitStatus status;
}

/// @notice A request paired with its live fill preview, for one-call scans. `id` is the registry key (a
///         `Request` does not carry its own id); `filledShares`/`assetsOut` mirror `previewFill` and are 0
///         when the request is closed, expired, or has no backing right now.
/// @param id The request's registry id.
/// @param request The stored request.
/// @param filledShares Shares fillable right now (see `previewFill`).
/// @param assetsOut Assets those shares would yield right now (see `previewFill`).
struct RequestPreview {
    uint256 id;
    Request request;
    uint256 filledShares;
    uint256 assetsOut;
}
