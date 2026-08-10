// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Request} from "../types/ExitBookTypes.sol";

/// @title IExitBook
/// @notice Source-agnostic surface of an exit book: configure the service fee, fill and cancel requests, and
///         read them. Concrete books (ERC-4626, Morpho, ...) add their own
///         `placeExitRequest` and allow-list admin on top.
interface IExitBook {
    // ---
    // ROLES
    // ---

    /// @notice Role allowed to pause request placement and fills.
    function PAUSER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to resume request placement and fills.
    function RESUMER_ROLE() external view returns (bytes32);

    // ---
    // CONFIG
    // ---

    /// @notice Set the service fee and its recipient. `FEE_MANAGER_ROLE` only.
    /// @param recipient Address paid the service fee (a cut of the priority fee); the zero address is allowed only
    ///        when `fee` is 0.
    /// @param fee Service-fee rate (WAD), capped at `MAX_SERVICE_FEE`.
    function setServiceFee(address recipient, uint256 fee) external;

    // ---
    // PAUSE
    // ---

    /// @notice Whether request placement and fills are paused.
    function paused() external view returns (bool);

    /// @notice Pause request placement and fills until an authorized resume. `PAUSER_ROLE` only.
    function pause() external;

    /// @notice Resume request placement and fills. `RESUMER_ROLE` only.
    function resume() external;

    // ---
    // FILL
    // ---

    /// @notice Debit request `id` and withdraw exactly `fillAssets` from its source. The receiver gets
    ///         `fillAssets` minus the priority fee; `rewardRecipient` gets the priority fee minus the service cut.
    ///         Reverts unless the source can honour the exact withdrawal. When share-burn protection is enabled,
    ///         every fill must also fit its proportional share limit. Callers prepare any required source liquidity
    ///         before filling, either beforehand or earlier in the same transaction.
    /// @param id The request to fill.
    /// @param fillAssets Exact asset amount to debit from the request, withdraw, and use as the priority-fee basis.
    /// @param rewardRecipient Non-zero address credited the priority fee minus the service cut.
    function fillExitRequest(uint256 id, uint256 fillAssets, address rewardRecipient) external;

    // ---
    // LENDER
    // ---

    /// @notice Cancel an open request, including while paused or after its deadline. Sets the remaining amount to
    ///         zero and moves no assets. Caller must own it.
    /// @param id The request to cancel.
    function cancelExitRequest(uint256 id) external;

    // ---
    // READS
    // ---

    /// @notice The stored request at `id` (a zeroed `NotCreated` record if it never existed).
    /// @param id The request id.
    function getExitRequest(uint256 id) external view returns (Request memory);

    /// @notice The stored requests at `ids` (closed and `NotCreated` records included) with no source calls.
    /// @param ids The request ids to read.
    /// @return requests The request records, one per id, in the same order.
    function getRequests(uint256[] calldata ids) external view returns (Request[] memory requests);

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
    /// @return ids The owner's request ids in `[offset, offset + count)`.
    function getOwnerRequestIds(address owner, uint256 offset, uint256 count)
        external
        view
        returns (uint256[] memory ids);
}
