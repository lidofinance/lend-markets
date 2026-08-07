// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ExitBookBase} from "./ExitBookBase.sol";
import {IErc4626ExitBook} from "../interfaces/IErc4626ExitBook.sol";
import {Request, PriorityRamp, Sizing} from "../types/ExitBookTypes.sol";

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
        PriorityRamp calldata ramp,
        uint256 deadline
    ) external returns (uint256 id) {
        if (!isVaultAllowed[vault]) revert VaultNotAllowed();

        id = _createRequest(msg.sender, receiver, _size(vault, assets, minFillAssets), ramp, deadline);

        vaultOf[id] = vault;
    }

    /// @dev Size a placement: the lender names an asset amount, the request is stored in the shares it buys at
    ///      the vault's current share rate. What they actually hold is not checked — the fill reads it live.
    function _size(IERC4626 vault, uint256 assets, uint256 minFillAssets) private view returns (Sizing memory sizing) {
        sizing.asset = IERC20(vault.asset());
        sizing.shares = vault.convertToShares(assets);
        sizing.quotedAssets = vault.convertToAssets(sizing.shares);
        sizing.minShareRate = _vaultShareRate(vault);
        // A minimum at the request's own size already admits only a full close, and capping there keeps an
        // unbounded minimum out of the conversion.
        sizing.minFillShares =
            minFillAssets > sizing.quotedAssets ? sizing.shares : vault.convertToShares(minFillAssets);
    }

    // ---
    // SOURCE OPERATIONS
    // ---

    /// @dev What the fill can take right now: the remaining size, capped by the owner's `maxRedeem` and by the
    ///      allowance they granted this book — together with the vault's current share rate.
    function _availableShares(uint256 id, Request storage request)
        internal
        view
        override
        returns (uint256 availableShares, uint256 shareRate)
    {
        IERC4626 vault = vaultOf[id];
        uint256 redeemable = vault.maxRedeem(request.owner);
        uint256 allowed = vault.allowance(request.owner, address(this));
        availableShares = Math.min(Math.min(request.sizeRemaining, redeemable), allowed);
        shareRate = _vaultShareRate(vault);
    }

    function _asset(uint256 id) internal view override returns (IERC20) {
        return IERC20(vaultOf[id].asset());
    }

    function _redeem(uint256 id, address account, uint256 shares) internal override {
        vaultOf[id].redeem(shares, address(this), account);
    }

    function _depositLiquidity(uint256 id, IERC20 asset, uint256 depositAssets, address filler) internal override {
        IERC4626 vault = vaultOf[id];
        asset.forceApprove(address(vault), depositAssets);
        vault.deposit(depositAssets, filler);
    }

    /// @dev Loan assets per `SHARE_RATE_UNIT` vault shares.
    function _vaultShareRate(IERC4626 vault) private view returns (uint256) {
        return vault.convertToAssets(SHARE_RATE_UNIT);
    }

    function _previewAssets(uint256 id, uint256 shares) internal view override returns (uint256) {
        return vaultOf[id].previewRedeem(shares);
    }
}
