// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMorpho, MarketParams} from "@lido-blue/src/interfaces/IMorpho.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IWstETH is IERC20 {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function stETH() external view returns (address);
}

interface ILidoBlueVault is IERC20 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @title LidoBlueDepositGateway
/// @author Lido Lending contributors.
/// @notice Stateless entry zaps for a WETH/wstETH `LidoBlue` market: lenders supply in ETH or WETH
///         (or straight into the vault), borrowers post collateral in stETH. Wrapping convenience
///         lives here so the core stays WETH/wstETH-only.
/// @dev Entry-only: every zap adds value to `onBehalf` / `receiver`, so none of them needs a core
///      authorization — a token approval to this gateway is enough. Holds no funds between
///      transactions.
contract LidoBlueDepositGateway {
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error ZeroAddress();
    error VaultAssetMismatch();

    event SuppliedCollateralWithStETH(
        address indexed caller, address indexed onBehalf, uint256 stEthAmount, uint256 wstEthAmount
    );
    event SuppliedWithETH(address indexed caller, address indexed onBehalf, uint256 ethAmount, uint256 shares);
    event SuppliedWithWETH(address indexed caller, address indexed onBehalf, uint256 wethAmount, uint256 shares);
    event DepositedETHToVault(address indexed caller, address indexed receiver, uint256 ethAmount, uint256 shares);

    IMorpho public immutable MORPHO;
    IWETH public immutable WETH;
    IWstETH public immutable WSTETH;
    IERC20 public immutable STETH;
    ILidoBlueVault public immutable VAULT;

    MarketParams internal _params;

    constructor(address morpho, MarketParams memory params, address vault) {
        if (
            morpho == address(0) || params.loanToken == address(0) || params.collateralToken == address(0)
                || vault == address(0)
        ) {
            revert ZeroAddress();
        }
        if (ILidoBlueVault(vault).asset() != params.loanToken) revert VaultAssetMismatch();

        MORPHO = IMorpho(morpho);
        WETH = IWETH(params.loanToken);
        WSTETH = IWstETH(params.collateralToken);
        STETH = IERC20(IWstETH(params.collateralToken).stETH());
        VAULT = ILidoBlueVault(vault);
        _params = params;

        IERC20(params.loanToken).forceApprove(morpho, type(uint256).max);
        IERC20(params.collateralToken).forceApprove(morpho, type(uint256).max);
        STETH.forceApprove(params.collateralToken, type(uint256).max);
        IERC20(params.loanToken).forceApprove(vault, type(uint256).max);
    }

    function marketParams() external view returns (MarketParams memory) {
        return _params;
    }

    /// @notice Pull stETH from the caller, wrap it to wstETH and post it as collateral for `onBehalf`.
    /// @return wstEthAmount wstETH supplied as collateral.
    function supplyCollateralWithStETH(uint256 stEthAmount, address onBehalf)
        external
        returns (uint256 wstEthAmount)
    {
        if (stEthAmount == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();

        // stETH transfers can deliver 1-2 wei less than asked (rebasing shares math), so wrap the
        // measured delta rather than the requested amount.
        uint256 stBefore = STETH.balanceOf(address(this));
        STETH.safeTransferFrom(msg.sender, address(this), stEthAmount);
        uint256 stReceived = STETH.balanceOf(address(this)) - stBefore;

        wstEthAmount = WSTETH.wrap(stReceived);
        MORPHO.supplyCollateral(_params, wstEthAmount, onBehalf, "");

        emit SuppliedCollateralWithStETH(msg.sender, onBehalf, stReceived, wstEthAmount);
    }

    /// @notice Wrap `msg.value` to WETH and supply it for `onBehalf`.
    /// @return assets WETH supplied. @return shares Supply shares credited to `onBehalf`.
    function supplyWithETH(address onBehalf) external payable returns (uint256 assets, uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();

        WETH.deposit{value: msg.value}();
        (assets, shares) = MORPHO.supply(_params, msg.value, 0, onBehalf, "");

        emit SuppliedWithETH(msg.sender, onBehalf, assets, shares);
    }

    /// @notice Pull WETH from the caller and supply it for `onBehalf`.
    /// @return assets WETH supplied. @return shares Supply shares credited to `onBehalf`.
    function supplyWithWETH(uint256 wethAmount, address onBehalf)
        external
        returns (uint256 assets, uint256 shares)
    {
        if (wethAmount == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();

        IERC20(address(WETH)).safeTransferFrom(msg.sender, address(this), wethAmount);
        (assets, shares) = MORPHO.supply(_params, wethAmount, 0, onBehalf, "");

        emit SuppliedWithWETH(msg.sender, onBehalf, assets, shares);
    }

    /// @notice Wrap `msg.value` to WETH and deposit it into the vault; shares mint to `receiver`.
    /// @return shares Vault shares minted to `receiver`.
    function depositETHToVault(address receiver) external payable returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        WETH.deposit{value: msg.value}();
        shares = VAULT.deposit(msg.value, receiver);

        emit DepositedETHToVault(msg.sender, receiver, msg.value, shares);
    }
}
