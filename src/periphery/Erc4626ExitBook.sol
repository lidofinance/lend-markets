// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ExitBookBase} from "./ExitBookBase.sol";
import {IErc4626ExitBook} from "../interfaces/IErc4626ExitBook.sol";
import {PriorityRamp} from "../types/ExitBookTypes.sol";

/// @title Erc4626ExitBook
/// @author Lido
/// @notice The ERC-4626 exit book: a request is backed by the lender's vault shares, and a fill withdraws the
///         requested assets against them. Governance picks the allowed vaults. No Morpho dependency.
contract Erc4626ExitBook is ExitBookBase, IErc4626ExitBook {
    // ---
    // ERRORS
    // ---

    error VaultNotAllowed();
    error InsufficientBacking();
    error ZeroVault();

    // ---
    // EVENTS
    // ---

    event VaultAllowedSet(address indexed vault, bool allowed);

    // ---
    // STORAGE
    // ---

    /// @inheritdoc IErc4626ExitBook
    mapping(IERC4626 vault => bool) public isVaultAllowed;

    /// @inheritdoc IErc4626ExitBook
    mapping(uint256 id => IERC4626) public vaultOf;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param admin Non-zero initial holder of `DEFAULT_ADMIN_ROLE`.
    /// @param maxLifetime_ Non-zero maximum request lifetime in seconds.
    constructor(address admin, uint256 maxLifetime_) ExitBookBase(admin, maxLifetime_) {}

    // ---
    // CONFIG
    // ---

    /// @inheritdoc IErc4626ExitBook
    function setVaultAllowed(IERC4626 vault, bool allowed) external onlyRole(ALLOWLIST_MANAGER_ROLE) {
        if (address(vault) == address(0)) revert ZeroVault();
        isVaultAllowed[vault] = allowed;
        emit VaultAllowedSet(address(vault), allowed);
    }

    // ---
    // PLACE
    // ---

    /// @inheritdoc IErc4626ExitBook
    function placeExitRequest(
        IERC4626 vault,
        uint256 assets,
        address receiver,
        uint256 minFillAssets,
        uint256 maxShareBurn,
        PriorityRamp calldata ramp,
        uint256 deadline
    ) external returns (uint256 id) {
        if (paused) revert EnforcedPause();

        if (!isVaultAllowed[vault]) revert VaultNotAllowed();
        if (assets == 0) revert ZeroAssets();

        uint256 requiredShares = vault.previewWithdraw(assets);
        if (vault.allowance(msg.sender, address(this)) < requiredShares || vault.balanceOf(msg.sender) < requiredShares)
        revert InsufficientBacking();

        IERC20 asset = IERC20(vault.asset());
        id = _createRequest(
            msg.sender, receiver, asset, assets, minFillAssets, requiredShares, maxShareBurn, ramp, deadline
        );

        vaultOf[id] = vault;
    }

    // ---
    // SOURCE OPERATIONS
    // ---

    function _withdraw(uint256 id, address account, uint256 assets) internal override returns (uint256 sharesBurned) {
        return vaultOf[id].withdraw(assets, address(this), account);
    }
}
