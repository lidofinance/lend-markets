// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IWstEth} from "@bundler3/src/interfaces/IWstEth.sol";
import {IStEth} from "@bundler3/src/interfaces/IStEth.sol";

import {GeneralAdapter1, ErrorsLib, SafeERC20, IERC20} from "@bundler3/src/adapters/GeneralAdapter1.sol";
import {MathRayLib} from "@bundler3/src/libraries/MathRayLib.sol";

/// @author Morpho Labs. Modified by Lido.
/// @notice Adapter contract specific to Ethereum n°1.
/// @dev Vendored from bundler3's `EthereumGeneralAdapter1` with the MORPHO token surface removed
///      (`MORPHO_TOKEN`, `MORPHO_TOKEN_LEGACY`, `MORPHO_WRAPPER`, their constructor arguments, and the
///      `morphoWrapperDepositFor` / `morphoWrapperWithdrawTo` actions); everything else is upstream.
contract EthereumGeneralAdapter1 is GeneralAdapter1 {
    using MathRayLib for uint256;

    /* IMMUTABLES */

    /// @dev The address of the stETH token.
    address public immutable ST_ETH;

    /// @dev The address of the wstETH token.
    address public immutable WST_ETH;

    /* CONSTRUCTOR */

    /// @param bundler3 The address of the Bundler3 contract.
    /// @param morpho The address of Morpho.
    /// @param weth The address of the WETH token.
    /// @param wStEth The address of the wstETH token.
    constructor(address bundler3, address morpho, address weth, address wStEth)
        GeneralAdapter1(bundler3, morpho, weth)
    {
        require(wStEth != address(0), ErrorsLib.ZeroAddress());

        ST_ETH = IWstEth(wStEth).stETH();
        WST_ETH = wStEth;
    }

    /* LIDO ACTIONS */

    /// @notice Stakes ETH via Lido.
    /// @dev ETH must have been previously sent to the adapter.
    /// @param amount The amount of ETH to stake. Pass `type(uint).max` to stake the adapter's ETH balance.
    /// @param maxSharePriceE27 The maximum amount of wei to pay for minting 1 share, scaled by 1e27.
    /// @param referral The address of the referral regarding the Lido Rewards-Share Program.
    /// @param receiver The account receiving the stETH tokens.
    function stakeEth(uint256 amount, uint256 maxSharePriceE27, address referral, address receiver)
        external
        onlyBundler3
    {
        if (amount == type(uint256).max) amount = address(this).balance;

        require(amount != 0, ErrorsLib.ZeroAmount());

        uint256 sharesReceived = IStEth(ST_ETH).submit{value: amount}(referral);
        require(amount.rDivUp(sharesReceived) <= maxSharePriceE27, ErrorsLib.SlippageExceeded());

        if (receiver != address(this)) SafeERC20.safeTransfer(IERC20(ST_ETH), receiver, amount);
    }

    /// @notice Wraps stETH to wStETH.
    /// @dev stETH must have been previously sent to the adapter.
    /// @param amount The amount of stEth to wrap. Pass `type(uint).max` to wrap the adapter's balance.
    /// @param receiver The account receiving the wStETH tokens.
    function wrapStEth(uint256 amount, address receiver) external onlyBundler3 {
        if (amount == type(uint256).max) amount = IERC20(ST_ETH).balanceOf(address(this));

        require(amount != 0, ErrorsLib.ZeroAmount());

        // The wStEth's allowance is not reset as it is trusted.
        SafeERC20.forceApprove(IERC20(ST_ETH), WST_ETH, type(uint256).max);

        uint256 received = IWstEth(WST_ETH).wrap(amount);

        if (receiver != address(this) && received > 0) SafeERC20.safeTransfer(IERC20(WST_ETH), receiver, received);
    }

    /// @notice Unwraps wStETH to stETH.
    /// @dev wStETH must have been previously sent to the adapter.
    /// @param amount The amount of wStEth to unwrap. Pass `type(uint).max` to unwrap the adapter's balance.
    /// @param receiver The account receiving the stETH tokens.
    function unwrapStEth(uint256 amount, address receiver) external onlyBundler3 {
        if (amount == type(uint256).max) amount = IERC20(WST_ETH).balanceOf(address(this));

        require(amount != 0, ErrorsLib.ZeroAmount());

        uint256 received = IWstEth(WST_ETH).unwrap(amount);
        if (receiver != address(this) && received > 0) SafeERC20.safeTransfer(IERC20(ST_ETH), receiver, received);
    }
}
