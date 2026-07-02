// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {ILidoLendOwner} from "../interfaces/ILidoLendOwner.sol";

/// @title LidoLendOwner
/// @author Lido Lending contributors.
/// @notice Role-gated owner of the `LidoLend` core. The core authorizes its admin surface against a single
///         `owner`; deployed as that owner, this facade re-exposes each owner-only call behind a distinct role
///         so the capabilities can be delegated independently.
contract LidoLendOwner is AccessControl, ILidoLendOwner {
    // ---
    // ROLES
    // ---

    /// @dev Creates markets on the core (controller-less and controlled). A market's controller and settle
    ///      opt-in are bound at creation and immutable thereafter, so this is a high-trust capability.
    bytes32 public constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");
    /// @dev Sets per-market fees and the global fee recipient on the core.
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    // ---
    // IMMUTABLES
    // ---

    /// @inheritdoc ILidoLendOwner
    ILidoLend public immutable LIDO_LEND;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param core          The `LidoLend` core this facade will own. The deploy must hand the core's `owner`
    ///                      to this facade after construction; the facade cannot do it itself.
    /// @param admin         Holder of `DEFAULT_ADMIN_ROLE`, which manages the capability roles and core
    ///                      ownership. Required.
    /// @param marketCreator Initial `MARKET_CREATOR_ROLE` holder; `address(0)` grants none (admin can later).
    /// @param feeManager    Initial `FEE_MANAGER_ROLE` holder; `address(0)` grants none (admin can later).
    constructor(ILidoLend core, address admin, address marketCreator, address feeManager) {
        if (address(core) == address(0) || admin == address(0)) revert ZeroAddress();
        LIDO_LEND = core;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (marketCreator != address(0)) _grantRole(MARKET_CREATOR_ROLE, marketCreator);
        if (feeManager != address(0)) _grantRole(FEE_MANAGER_ROLE, feeManager);
    }

    // ---
    // MARKET CREATION
    // ---

    /// @inheritdoc ILidoLendOwner
    function createMarket(MarketParams calldata marketParams) external onlyRole(MARKET_CREATOR_ROLE) {
        LIDO_LEND.createMarket(marketParams);
    }

    /// @inheritdoc ILidoLendOwner
    function createMarket(MarketParams calldata marketParams, address controller, bool enableSettlement)
        external
        onlyRole(MARKET_CREATOR_ROLE)
    {
        LIDO_LEND.createMarket(marketParams, controller, enableSettlement);
    }

    // ---
    // FEES
    // ---

    /// @inheritdoc ILidoLendOwner
    function setFee(MarketParams calldata marketParams, uint256 newFee) external onlyRole(FEE_MANAGER_ROLE) {
        LIDO_LEND.setFee(marketParams, newFee);
    }

    /// @inheritdoc ILidoLendOwner
    function setFeeRecipient(address newFeeRecipient) external onlyRole(FEE_MANAGER_ROLE) {
        LIDO_LEND.setFeeRecipient(newFeeRecipient);
    }

    // ---
    // OWNERSHIP
    // ---

    /// @inheritdoc ILidoLendOwner
    function transferLidoLendOwnership(address newOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOwner == address(0)) revert ZeroAddress();
        LIDO_LEND.setOwner(newOwner);
    }
}
