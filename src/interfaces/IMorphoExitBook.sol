// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IMorpho, Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IExitBook} from "./IExitBook.sol";
import {PriorityRamp} from "../types/ExitBookTypes.sol";

/// @title IMorphoExitBook
/// @notice Exit book backed by supply positions in governance-allowed Morpho markets. Extends the common
///         exit-book surface (`IExitBook`) with market placement and allow-list admin.
interface IMorphoExitBook is IExitBook {
    /// @notice The Morpho deployment this book reads positions from and withdraws against.
    /// @return The Morpho core contract.
    function MORPHO() external view returns (IMorpho);

    /// @notice Whether market `marketId` is allowed for new requests.
    /// @param marketId The market id to query.
    /// @return True if `marketId` is allowed.
    function isMarketAllowed(Id marketId) external view returns (bool);

    /// @notice The market params request `requestId` was placed against (empty if none).
    /// @param requestId The request id.
    /// @return The market's params.
    function marketParamsOf(uint256 requestId) external view returns (MarketParams memory);

    /// @notice Register `marketParams` (which must name a live Morpho market, checked on both allow and
    ///         disallow) and allow or disallow it for new requests. The params are kept permanently (so
    ///         requests already placed stay fillable after a disallow); disallowing only flips the gate.
    ///         Owner only.
    /// @param marketParams The market's full params; its id (the params' hash) is the allow-list key.
    /// @param allowed True to allow new requests against it; false to block them (already-placed ones still fill).
    function setMarketAllowed(MarketParams calldata marketParams, bool allowed) external;

    /// @notice Open an exit backed by `shares` of the caller's supply in an allowed Morpho market, named by
    ///         its `marketId`. Permission-only: the caller must have authorized this book on Morpho and hold
    ///         the `shares`.
    /// @param marketId The allowed market's id (its `MarketParams` hash, registered via `setMarketAllowed`).
    /// @param shares Supply shares to exit.
    /// @param ramp Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end.
    /// @param deadline Fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends.
    /// @param fullFillOnly When true a fill must cover the whole remaining size in one shot.
    /// @return id The new request id.
    function placeExitRequest(
        Id marketId,
        uint256 shares,
        PriorityRamp calldata ramp,
        uint256 deadline,
        bool fullFillOnly
    ) external returns (uint256 id);
}
