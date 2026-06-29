// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @title ILidoLendOwner
/// @notice Role-gated owner of the `LidoLend` core. The core has a single `owner`; this facade holds it and
///         splits the core's owner-only surface (market creation, fees, ownership transfer) across distinct
///         roles, so each capability can be delegated independently.
/// @dev Role-management events and the unauthorized-caller error come from OpenZeppelin's `IAccessControl`.
interface ILidoLendOwner {
    // ---
    // ERRORS
    // ---

    /// @notice Thrown when the core or an ownership target is the zero address.
    error ZeroAddress();

    // ---
    // VIEWS
    // ---

    /// @notice The `LidoLend` core this facade owns.
    function LIDO_LEND() external view returns (ILidoLend);

    // ---
    // MARKET CREATION (MARKET_CREATOR_ROLE)
    // ---

    /// @notice Create a controller-less market on the core.
    function createMarket(MarketParams calldata marketParams) external;
    /// @notice Create a controlled market on the core, binding `controller` and the `settle` opt-in.
    function createMarket(MarketParams calldata marketParams, address controller, bool enableSettlement) external;

    // ---
    // FEES (FEE_MANAGER_ROLE)
    // ---

    /// @notice Set the fee of an existing market.
    function setFee(MarketParams calldata marketParams, uint256 newFee) external;
    /// @notice Set the global fee recipient.
    function setFeeRecipient(address newFeeRecipient) external;

    // ---
    // OWNERSHIP (DEFAULT_ADMIN_ROLE)
    // ---

    /// @notice Hand the core's `owner` to `newOwner`, relinquishing this facade's control of the core. The
    ///         escape hatch for migrating to a different owner; irreversible from the facade's side.
    function transferLidoLendOwnership(address newOwner) external;
}
