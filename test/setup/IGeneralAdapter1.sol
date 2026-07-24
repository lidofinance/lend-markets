// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @dev Typed test surface of the vendored `src/adapters/EthereumGeneralAdapter1.sol` (including what
///      it inherits from `GeneralAdapter1` and `CoreAdapter`). The contract itself pins solc 0.8.28,
///      so 0.8.35 test code cannot import it; its artifact is deployed via `deployCode` and driven
///      through this interface. Signatures must match the vendored contract exactly.
interface IGeneralAdapter1 {
    function nativeTransfer(address receiver, uint256 amount) external;
    function erc20Transfer(address token, address receiver, uint256 amount) external;
    function erc20TransferFrom(address token, address receiver, uint256 amount) external;
    function wrapNative(uint256 amount, address receiver) external;
    function unwrapNative(uint256 amount, address receiver) external;
    function stakeEth(uint256 amount, uint256 maxSharePriceE27, address referral, address receiver) external;
    function wrapStEth(uint256 amount, address receiver) external;
    function unwrapStEth(uint256 amount, address receiver) external;
    function erc4626Deposit(address vault, uint256 assets, uint256 maxSharePriceE27, address receiver) external;
    function erc4626Redeem(address vault, uint256 shares, uint256 minSharePriceE27, address receiver, address owner)
        external;
    function morphoSupplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;
    function morphoBorrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 minSharePriceE27,
        address receiver
    ) external;
    function morphoRepay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        uint256 maxSharePriceE27,
        address onBehalf,
        bytes calldata data
    ) external;
    function morphoWithdrawCollateral(MarketParams calldata marketParams, uint256 assets, address receiver) external;
}
