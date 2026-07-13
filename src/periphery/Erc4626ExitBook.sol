// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ExitBookBase} from "./ExitBookBase.sol";
import {IErc4626ExitBook} from "../interfaces/IErc4626ExitBook.sol";
import {Request, PriorityRamp} from "../types/ExitBookTypes.sol";
import {WAD} from "../libs/Constants.sol";

/// @title Erc4626ExitBook
/// @author Lido
/// @notice The ERC-4626 exit book: a request is backed by the lender's vault shares, and a fill redeems
///         them. Governance picks the allowed vaults. Works with any ERC-4626 vault — no Morpho dependency.
contract Erc4626ExitBook is ExitBookBase, IErc4626ExitBook {
    using SafeERC20 for IERC20;

    // ---
    // ERRORS
    // ---

    error VaultNotAllowed();
    error InsufficientBacking();
    error ZeroVault();
    error ZeroPricePerShare();

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
        uint256 shares,
        PriorityRamp calldata ramp,
        uint256 deadline,
        bool fullFillOnly
    ) external returns (uint256 id) {
        if (!isVaultAllowed[vault]) revert VaultNotAllowed();

        uint256 pricePerShare = vault.convertToAssets(WAD);

        // A zero snapshot price pays the lender `owed = 0` on every fill and hands the whole redemption to the
        // filler. Reject it.
        if (pricePerShare == 0) revert ZeroPricePerShare();

        // Permission-only: shares stay with the lender; sanity-check now, the fill re-checks live.
        if (vault.allowance(msg.sender, address(this)) < shares || vault.balanceOf(msg.sender) < shares) {
            revert InsufficientBacking();
        }

        id = _createRequest(msg.sender, IERC20(vault.asset()), shares, pricePerShare, ramp, deadline, fullFillOnly);

        vaultOf[id] = vault;
    }

    // ---
    // SOURCE OPERATIONS
    // ---

    function _availableShares(uint256 id, Request storage request) internal view override returns (uint256) {
        IERC4626 vault = vaultOf[id];
        uint256 redeemable = vault.maxRedeem(request.owner);
        uint256 allowed = vault.allowance(request.owner, address(this));
        return Math.min(Math.min(request.sizeRemaining, redeemable), allowed);
    }

    function _redeem(uint256 id, address account, uint256 shares) internal override {
        vaultOf[id].redeem(shares, address(this), account);
    }

    function _depositLiquidity(uint256 id, IERC20 asset, uint256 depositAssets, address filler) internal override {
        IERC4626 vault = vaultOf[id];
        asset.forceApprove(address(vault), depositAssets);
        vault.deposit(depositAssets, filler);
    }

    function _previewAssets(uint256 id, uint256 shares) internal view override returns (uint256) {
        return vaultOf[id].previewRedeem(shares);
    }
}
