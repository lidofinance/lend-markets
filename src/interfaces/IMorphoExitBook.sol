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
    function MORPHO() external view returns (IMorpho);

    /// @notice Whether market `marketId` is allowed for new requests.
    /// @param marketId The market id to query.
    function isMarketAllowed(Id marketId) external view returns (bool);

    /// @notice The market params request `requestId` was placed against (empty if none).
    /// @param requestId The request id.
    function marketParamsOf(uint256 requestId) external view returns (MarketParams memory);

    /// @notice Register `marketParams` (which must name a live Morpho market, checked on both allow and
    ///         disallow) and allow or disallow it for new requests. The params are kept permanently (so
    ///         requests already placed stay fillable after a disallow); disallowing only flips the gate.
    ///         `ALLOWLIST_MANAGER_ROLE` only.
    /// @param marketParams The market's full params; its id (the params' hash) is the allow-list key.
    /// @param allowed True to allow new requests against it; false to block them (already-placed ones still fill).
    function setMarketAllowed(MarketParams calldata marketParams, bool allowed) external;

    /// @notice Open an exit against the caller's supply position in an allowed Morpho market, named by its
    ///         `marketId` and sized by the asset amount they want out. Permission-only: nothing is escrowed, and
    ///         the fill withdraws on the caller's behalf, so they must have authorized this book on Morpho.
    /// @param marketId The allowed market's id (its `MarketParams` hash, registered via `setMarketAllowed`).
    /// @param assets Loan-asset amount to exit. Converted to supply shares at the market's current share rate and
    ///        stored as the request's fixed size; the caller's holdings are not checked here, the fill reads them
    ///        live.
    /// @param receiver Address credited the lender's proceeds of every fill.
    /// @param ramp Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end.
    /// @param deadline Fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends.
    /// @param fullFillOnly When true a fill must cover the whole remaining size in one shot.
    /// @return id The new request id.
    function placeExitRequest(
        Id marketId,
        uint256 assets,
        address receiver,
        PriorityRamp calldata ramp,
        uint256 deadline,
        bool fullFillOnly
    ) external returns (uint256 id);
}
