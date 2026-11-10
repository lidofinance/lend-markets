/* ── MUTATION OwnerManagerBase #13 ──────────────────────────────
 * @desc:   Flips the manager leg of the authorization gate, so every caller except the manager can rewrite a market's rate curve.
 * @rules:  acLkiOnlyAuthorizedModifiesBaseRate, acLkiOnlyAuthorizedModifiesSlope1, acLkiOnlyAuthorizedModifiesSlope2
 * @conf:   certora/confs/LinearKinkIrm/properties.conf
 * @target: lib/lend-irm/src/common/OwnerManagerBase.sol
 * Was:     require(msg.sender == owner || msg.sender == manager, OwnerManagerErrors.NOT_AUTHORIZED);
 * Now:     require(msg.sender == owner || msg.sender != manager, OwnerManagerErrors.NOT_AUTHORIZED);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IOwnerManager} from "./IOwnerManager.sol";
import {OwnerManagerErrors} from "./OwnerManagerErrors.sol";

/// @title OwnerManagerBase
/// @author Lido.
/// @notice Two-role access base: the `owner` rotates itself and the `manager`, the `manager` shares only the
/// operational setters.
/// @dev Derived contracts set the initial roles via `_transferOwnership`/`_setManager` and gate functions with
/// `_checkOwner` or `_checkAuthorized`.
abstract contract OwnerManagerBase is IOwnerManager {
    // ---
    // STORAGE
    // ---

    /// @inheritdoc IOwnerManager
    address public override owner;

    /// @inheritdoc IOwnerManager
    address public override manager;

    // ---
    // OWNERSHIP & MANAGEMENT
    // ---

    /// @inheritdoc IOwnerManager
    function transferOwnership(address newOwner) external override {
        _checkOwner();
        _transferOwnership(newOwner);
    }

    /// @inheritdoc IOwnerManager
    function setManager(address newManager) external override {
        _checkOwner();
        _setManager(newManager);
    }

    /// @dev Reverts unless the caller is the owner.
    function _checkOwner() internal view {
        require(msg.sender == owner, OwnerManagerErrors.NOT_OWNER);
    }

    /// @dev Reverts unless the caller is the owner or the manager.
    function _checkAuthorized() internal view {
        require(msg.sender == owner || msg.sender != manager, OwnerManagerErrors.NOT_AUTHORIZED);
    }

    /// @dev Sets `owner`, reverting on the zero address.
    function _transferOwnership(address newOwner) internal {
        require(newOwner != address(0), OwnerManagerErrors.ZERO_ADDRESS);

        address previousOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /// @dev Sets `manager`, reverting on the zero address.
    function _setManager(address newManager) internal {
        require(newManager != address(0), OwnerManagerErrors.ZERO_ADDRESS);

        manager = newManager;
        emit ManagerSet(newManager);
    }
}
