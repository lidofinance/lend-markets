// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../types/SettlementTypes.sol";

/// @title ILidoLendOwner
/// @notice Role-gated governance facade bound to a `LidoLend` core. It is designed to hold the core's single-owner
///         authority, which must be transferred separately and can later be moved away. While it is the owner, the
///         facade splits the core's owner-only surface and per-market governance surface across distinct roles so
///         each capability can be delegated independently. Per-market calls resolve the target controller and
///         guardian registry from the core, giving governance one stable facade address for every market.
/// @dev Role-management events and the unauthorized-caller error come from OpenZeppelin's
///      `IAccessControlEnumerable`.
interface ILidoLendOwner is IAccessControlEnumerable {
    // ---
    // IMMUTABLES
    // ---

    /// @notice The `LidoLend` core this facade is bound to.
    function LIDO_LEND() external view returns (ILidoLend);

    // ---
    // ROLES
    // ---

    /// @notice Role allowed to create markets on the core.
    function MARKET_CREATOR_ROLE() external view returns (bytes32);

    /// @notice Role allowed to update core fees.
    function FEE_MANAGER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to update per-market controller policy.
    function MARKET_MANAGER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to manage guardian registries.
    function GUARDIAN_MANAGER_ROLE() external view returns (bytes32);

    // ---
    // ERRORS
    // ---

    /// @notice Thrown when the core, required admin, or an ownership target is the zero address.
    error ZeroAddress();

    /// @notice The market id has no controller on the core (unknown or controller-less).
    error UnknownMarket(Id marketId);

    // ---
    // MARKET CREATION (MARKET_CREATOR_ROLE)
    // ---

    /// @notice Create a controller-less market on the core.
    /// @dev Requires `MARKET_CREATOR_ROLE`.
    function createMarket(MarketParams calldata marketParams) external;
    /// @notice Create a controlled market on the core, binding `controller` and the `settle` opt-in.
    /// @dev Requires `MARKET_CREATOR_ROLE`.
    function createMarket(MarketParams calldata marketParams, address controller, bool enableSettlement) external;

    // ---
    // FEES (FEE_MANAGER_ROLE)
    // ---

    /// @notice Set the fee of an existing market.
    /// @dev Requires `FEE_MANAGER_ROLE`.
    function setFee(MarketParams calldata marketParams, uint256 newFee) external;
    /// @notice Set the global fee recipient.
    /// @dev Requires `FEE_MANAGER_ROLE`.
    function setFeeRecipient(address newFeeRecipient) external;

    // ---
    // MARKET MANAGEMENT (MARKET_MANAGER_ROLE)
    // ---

    /// @notice Set a market's supply cap. A zero cap disables it.
    /// @dev Requires `MARKET_MANAGER_ROLE`.
    function setMarketSupplyCap(Id marketId, uint256 cap) external;

    /// @notice Lift a market's freeze.
    /// @dev Requires `MARKET_MANAGER_ROLE`.
    function unfreezeMarket(Id marketId) external;

    /// @notice Replace a market's collateral-activation configuration.
    /// @dev Requires `MARKET_MANAGER_ROLE`.
    function setMarketCollateralActivationConfig(Id marketId, CollateralActivationConfig calldata config) external;

    /// @notice Replace a market's settlement configuration.
    /// @dev Requires `MARKET_MANAGER_ROLE`.
    function setMarketSettlementConfig(Id marketId, SettlementConfig calldata config) external;

    /// @notice Set whether a caller's supplies activate instantly on a market.
    /// @dev Requires `MARKET_MANAGER_ROLE`.
    function setInstantActivation(Id marketId, address caller, bool enabled) external;

    // ---
    // GUARDIAN MANAGEMENT (GUARDIAN_MANAGER_ROLE)
    // ---

    /// @notice Add a guardian to the registry used by a market.
    /// @dev Requires `GUARDIAN_MANAGER_ROLE`.
    function addGuardian(Id marketId, address guardian) external;

    /// @notice Replace one guardian with another in the registry used by a market.
    /// @dev Requires `GUARDIAN_MANAGER_ROLE`.
    function replaceGuardian(Id marketId, address oldGuardian, address newGuardian) external;

    /// @notice Remove a guardian from the registry used by a market.
    /// @dev Requires `GUARDIAN_MANAGER_ROLE`.
    function removeGuardian(Id marketId, address guardian) external;

    /// @notice Set the quorum of the guardian registry used by a market.
    /// @dev Requires `GUARDIAN_MANAGER_ROLE`.
    function setGuardiansQuorum(Id marketId, uint256 quorum) external;

    /// @notice Set the suspect window of the guardian registry used by a market.
    /// @dev Requires `GUARDIAN_MANAGER_ROLE`.
    function setGuardiansSuspectWindow(Id marketId, uint256 suspectWindow) external;

    /// @notice Lift `account`'s ban in each market, resolving that market's guardian registry independently.
    /// @dev Requires `GUARDIAN_MANAGER_ROLE`.
    function unbanGuardianSignals(Id[] calldata marketIds, address account) external;

    // ---
    // OWNERSHIP (DEFAULT_ADMIN_ROLE)
    // ---

    /// @notice Hand the core's `owner` to `newOwner`, relinquishing this facade's control of the core. The
    ///         escape hatch for migrating to a different owner; irreversible from the facade's side. Only
    ///         core ownership moves: facade role memberships remain unchanged and are not granted to `newOwner`.
    /// @dev Requires `DEFAULT_ADMIN_ROLE`.
    function transferLidoLendOwnership(address newOwner) external;
}
