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
    ///         disallow) and allow or disallow it for new requests. The params are kept permanently;
    ///         disallowing only flips the placement gate and does not change existing fill eligibility.
    ///         `ALLOWLIST_MANAGER_ROLE` only.
    /// @param marketParams The market's full params; its id (the params' hash) is the allow-list key.
    /// @param allowed True to allow new requests; false to block them without changing existing fill eligibility.
    function setMarketAllowed(MarketParams calldata marketParams, bool allowed) external;

    /// @notice Open an asset-denominated exit against the caller's supply position in an allowed Morpho market.
    ///         Nothing is escrowed. Placement snapshots the full request's supply-share quote and requires enough
    ///         current supply, but does not reserve it. Each fill debits and withdraws the same exact asset amount,
    ///         so authorization must remain live.
    /// @param marketId The allowed market's id (its `MarketParams` hash, registered via `setMarketAllowed`).
    /// @param assets Loan-asset amount to debit across fills. Must fit `uint128`.
    /// @param receiver Address credited the filled amount minus the priority fee.
    /// @param minFillAssets Smallest amount a non-final fill may process; 0 for no minimum. A fill that
    ///        closes the whole remaining request always qualifies. Values above `assets` are capped to `assets`.
    /// @param maxShareBurn Nominal full-request supply-share budget. A fill may burn at most
    ///        `ceil(maxShareBurn * fillAssets / assetsTotal)`. Across a split request, total burn may exceed this
    ///        value by at most one raw share unit per additional fill. Must fit `uint128`; 0 disables the limit,
    ///        and a non-zero value must cover the placement share quote.
    /// @param ramp Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end.
    /// @param deadline Strictly future fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends.
    /// @return id The new request id.
    function placeExitRequest(
        Id marketId,
        uint256 assets,
        address receiver,
        uint256 minFillAssets,
        uint256 maxShareBurn,
        PriorityRamp calldata ramp,
        uint256 deadline
    ) external returns (uint256 id);
}
