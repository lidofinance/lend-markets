// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Request, RequestPreview} from "../types/ExitBookTypes.sol";

/// @title IExitBook
/// @notice Source-agnostic surface of an exit book: configure the service fee, fill and cancel requests, and
///         read them (with optional live fill previews). Concrete books (ERC-4626, Morpho, ...) add their own
///         `placeExitRequest` and allow-list admin on top.
interface IExitBook {
    /// @notice Thrown when a request's full share amount quotes to zero assets at placement.
    error ZeroAssetQuote();

    // ---
    // CONFIG
    // ---

    /// @notice Set the service fee and its recipient. `FEE_MANAGER_ROLE` only.
    /// @param recipient Address paid the service fee (a cut of each fill's filler reward); the zero address is
    ///        allowed only when `fee` is 0.
    /// @param fee Service-fee rate (WAD), capped at `MAX_SERVICE_FEE`.
    function setServiceFee(address recipient, uint256 fee) external;

    // ---
    // FILL
    // ---

    /// @notice Fill request `id` against available source liquidity, paying the lender, the filler (caller),
    ///         and the service in the same transaction.
    /// @param id The request to fill.
    /// @param depositAssets Asset amount to first deposit into the request's source (becoming the depositor) so
    ///        the fill can be honoured; 0 to fill against existing liquidity only.
    /// @param minAssetsOut Slippage floor on the redeem proceeds: the fill reverts (rolling back any deposit)
    ///        if fewer assets arrive; 0 to skip.
    function fillExitRequest(uint256 id, uint256 depositAssets, uint256 minAssetsOut) external;

    // ---
    // LENDER
    // ---

    /// @notice Cancel an open request; nothing is refunded (the book holds no balances). Caller must own it.
    /// @param id The request to cancel.
    function cancelExitRequest(uint256 id) external;

    // ---
    // READS
    // ---

    /// @notice The stored request at `id` (a zeroed record if it never existed).
    /// @param id The request id.
    function getExitRequest(uint256 id) external view returns (Request memory);

    /// @notice The stored requests at `ids` (closed ones included) — a cheap batch read with no source calls.
    /// @param ids The request ids to read.
    /// @return The request records, one per id, in the same order.
    function getRequests(uint256[] calldata ids) external view returns (Request[] memory);

    /// @notice The last request id issued (ids start at 1; 0 means none yet).
    /// @return The highest request id issued so far; callers scan the `[1, lastRequestId]` range.
    function lastRequestId() external view returns (uint256);

    /// @notice How many requests `owner` has ever opened.
    /// @param owner The lender to count requests for.
    function getOwnerRequestCount(address owner) external view returns (uint256);

    /// @notice A page of `owner`'s request ids in creation order (closed ones included).
    /// @param owner The lender whose request ids to read.
    /// @param offset Index in the owner's id list to start from.
    /// @param count Maximum number of ids to return (clamped to what remains).
    /// @return The owner's request ids in `[offset, offset + count)`.
    function getOwnerRequestIds(address owner, uint256 offset, uint256 count) external view returns (uint256[] memory);

    /// @notice `previewFill` for each id in `ids` (an off-chain-gathered set), in one call.
    /// @param ids The request ids to preview.
    /// @return One preview per id, in the same order.
    function getRequestPreviews(uint256[] calldata ids) external view returns (RequestPreview[] memory);

    /// @notice The request at `id` paired with its live fill preview — the single-id `getRequestPreviews`.
    /// @param id The request to preview.
    /// @return The request with the shares fillable now and the assets they would yield (all 0 if the request
    ///         is closed, expired, or has no backing).
    function previewFill(uint256 id) external view returns (RequestPreview memory);
}
