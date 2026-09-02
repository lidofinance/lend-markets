// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CoreAdapter} from "@bundler3/src/adapters/CoreAdapter.sol";
import {ErrorsLib} from "@bundler3/src/libraries/ErrorsLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILidoLendERC4626} from "../interfaces/ILidoLendERC4626.sol";

/// @title LidoLendVaultAdapter
/// @author Lido
/// @notice Bundler3 adapter for the LidoLend vault's fallback exit. Users approve their vault shares
///         to this adapter; a bundle can then only ever exit the position of the user who started it.
contract LidoLendVaultAdapter is CoreAdapter {
    /// @notice The exit pays out less total value than the caller's minimum.
    /// @param exitAssets The exit's total payout in loan tokens: loan tokens paid plus debt canceled.
    /// @param minExitAssets The caller's minimum total payout.
    error ExitBelowMinimum(uint256 exitAssets, uint256 minExitAssets);

    /// @notice The exit burns fewer shares than the caller's minimum.
    /// @param sharesBurned Shares the exit burned.
    /// @param minSharesBurned The caller's minimum burn.
    error BurnBelowMinimum(uint256 sharesBurned, uint256 minSharesBurned);

    /// @param bundler3 The address of the Bundler3 contract.
    constructor(address bundler3) CoreAdapter(bundler3) {}

    /// @notice Exits vault shares of the bundle initiator through the vault's fallback exit: what free
    ///         market liquidity covers is paid in loan tokens, the rest is settled for borrower
    ///         collateral.
    /// @dev The owner of the burned shares is always the bundle initiator, so a share approval given
    ///      to this adapter can only be spent by a bundle its own owner started.
    /// @param vault The LidoLend vault to exit.
    /// @param shares Vault shares to burn. Pass `type(uint256).max` for the initiator's full balance.
    /// @param maxIterations Cap on settlement-loop iterations; 0 uses the vault default.
    /// @param receiver Receives both payout tokens. When it is an adapter, later calls in the bundle
    ///        must transfer both out of it.
    /// @param minExitAssets Minimum total payout, in loan tokens: the loan tokens paid plus the debt
    ///        the settlement canceled. One minimum covers both parts together, independent of how
    ///        the payout splits between them.
    /// @param minSharesBurned Minimum shares the exit must burn. The exit may burn fewer than
    ///        requested; pass `shares` to require all or nothing.
    function fallbackExit(
        address vault,
        uint256 shares,
        uint256 maxIterations,
        address receiver,
        uint256 minExitAssets,
        uint256 minSharesBurned
    ) external onlyBundler3 {
        if (receiver == address(0)) revert ErrorsLib.ZeroAddress();

        address owner = initiator();
        if (shares == type(uint256).max) shares = IERC20(vault).balanceOf(owner);
        if (shares == 0) revert ErrorsLib.ZeroShares();

        (uint256 sharesBurned, uint256 loanAssets,, uint256 debtCanceled) =
            ILidoLendERC4626(vault).fallbackExit(shares, receiver, owner, maxIterations);

        if (sharesBurned < minSharesBurned) revert BurnBelowMinimum(sharesBurned, minSharesBurned);

        uint256 exitAssets = loanAssets + debtCanceled;
        if (exitAssets < minExitAssets) revert ExitBelowMinimum(exitAssets, minExitAssets);
    }
}
