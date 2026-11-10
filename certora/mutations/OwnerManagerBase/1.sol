/* ── MUTATION OwnerManagerBase #1 ──────────────────────────────
 * @desc:   Inverts the owner gate, so every account except the owner can transfer ownership or set the manager.
 * @rules:  acIrrOnlyOwnerModifiesOwner, acIrrOnlyOwnerModifiesManager
 * @conf:   certora/confs/IrmRouter/properties.conf
 * @target: lib/lend-irm/src/common/OwnerManagerBase.sol
 * Was:     require(msg.sender == owner, OwnerManagerErrors.NOT_OWNER);
 * Now:     require(msg.sender != owner, OwnerManagerErrors.NOT_OWNER);
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
        require(msg.sender != owner, OwnerManagerErrors.NOT_OWNER);
    }

    /// @dev Reverts unless the caller is the owner or the manager.
    function _checkAuthorized() internal view {
        require(msg.sender == owner || msg.sender == manager, OwnerManagerErrors.NOT_AUTHORIZED);
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
