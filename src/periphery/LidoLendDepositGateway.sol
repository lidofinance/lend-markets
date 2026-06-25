// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

import {ILidoLendDepositGateway, IWETH, IWstETH} from "../interfaces/ILidoLendDepositGateway.sol";

/// @title LidoLendDepositGateway
/// @author Lido
/// @notice Stateless entry zaps for WETH/wstETH `LidoLend` markets: lenders supply in ETH or WETH (or
///         straight into the vault), borrowers post collateral in stETH. Wrapping convenience lives here so
///         the core stays WETH/wstETH-only.
/// @dev Entry-only: every zap adds value to `onBehalf` / `receiver`, so none of them needs a core
///      authorization — a token approval to this gateway is enough. Holds no funds between transactions,
///      which is also what makes the unlimited constructor approvals to the core and the vault safe: there
///      is never a balance for them to spend outside a zap. Each zap names its target market in calldata and
///      checks the one token it actually moves — the WETH supply zaps require the loan token to be WETH, the
///      stETH collateral zap requires the collateral token to be wstETH — so the gateway only ever supplies
///      the token it just wrapped; the market identity itself is never stored.
contract LidoLendDepositGateway is ILidoLendDepositGateway {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using SafeERC20 for IWstETH;

    // ---
    // IMMUTABLES
    // ---

    /// @inheritdoc ILidoLendDepositGateway
    IWETH public immutable WETH;

    /// @inheritdoc ILidoLendDepositGateway
    IERC20 public immutable STETH;

    /// @inheritdoc ILidoLendDepositGateway
    IWstETH public immutable WSTETH;

    /// @inheritdoc ILidoLendDepositGateway
    IMorpho public immutable MORPHO;

    /// @inheritdoc ILidoLendDepositGateway
    IERC4626 public immutable WETH_VAULT;

    // ---
    // CONSTRUCTOR
    // ---

    /// @notice Pin the gateway to the `weth` / `wstEth` token pair and to `vault`, and grant the unlimited
    ///         approvals the zaps rely on: WETH and wstETH to the core, stETH to wstETH for wrapping, WETH to
    ///         the vault. stETH is read from `wstEth`. Reverts on any zero address or a vault whose asset is
    ///         not WETH.
    constructor(address morpho, address weth, address wstEth, address vault) {
        if (weth == address(0)) revert ZeroWeth();
        if (wstEth == address(0)) revert ZeroWstEth();
        if (morpho == address(0)) revert ZeroMorpho();
        if (vault == address(0)) revert ZeroVault();

        if (IERC4626(vault).asset() != weth) revert VaultAssetMismatch();

        WETH = IWETH(weth);
        WSTETH = IWstETH(wstEth);
        STETH = IERC20(WSTETH.stETH());

        MORPHO = IMorpho(morpho);
        WETH_VAULT = IERC4626(vault);

        WETH.forceApprove(morpho, type(uint256).max);
        WETH.forceApprove(vault, type(uint256).max);
        STETH.forceApprove(wstEth, type(uint256).max);
        WSTETH.forceApprove(morpho, type(uint256).max);
    }

    // ---
    // ZAPS
    // ---

    /// @inheritdoc ILidoLendDepositGateway
    function supplyCollateralWithStEth(MarketParams calldata params, uint256 stEthAmount, address onBehalf)
        external
        returns (uint256 wstEthAmount)
    {
        if (params.collateralToken != address(WSTETH)) revert CollateralTokenMismatch();

        if (stEthAmount == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroOnBehalf();

        // stETH transfers can deliver 1-2 wei less than asked (rebasing shares math), so wrap the
        // measured delta rather than the requested amount.
        uint256 stEthBefore = STETH.balanceOf(address(this));
        STETH.safeTransferFrom(msg.sender, address(this), stEthAmount);
        uint256 stEthReceived = STETH.balanceOf(address(this)) - stEthBefore;

        wstEthAmount = WSTETH.wrap(stEthReceived);
        MORPHO.supplyCollateral(params, wstEthAmount, onBehalf, "");

        emit SuppliedCollateralWithStETH(msg.sender, onBehalf, stEthReceived, wstEthAmount);
    }

    /// @inheritdoc ILidoLendDepositGateway
    function supplyWithEth(MarketParams calldata params, address onBehalf)
        external
        payable
        returns (uint256 assets, uint256 shares)
    {
        if (params.loanToken != address(WETH)) revert LoanTokenMismatch();

        if (msg.value == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroOnBehalf();

        WETH.deposit{value: msg.value}();
        (assets, shares) = MORPHO.supply(params, msg.value, 0, onBehalf, "");

        emit SuppliedWithETH(msg.sender, onBehalf, assets, shares);
    }

    /// @inheritdoc ILidoLendDepositGateway
    function supplyWithWeth(MarketParams calldata params, uint256 wethAmount, address onBehalf)
        external
        returns (uint256 assets, uint256 shares)
    {
        if (params.loanToken != address(WETH)) revert LoanTokenMismatch();

        if (wethAmount == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroOnBehalf();

        WETH.safeTransferFrom(msg.sender, address(this), wethAmount);
        (assets, shares) = MORPHO.supply(params, wethAmount, 0, onBehalf, "");

        emit SuppliedWithWETH(msg.sender, onBehalf, assets, shares);
    }

    /// @inheritdoc ILidoLendDepositGateway
    function depositEthToVault(address receiver) external payable returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroReceiver();

        WETH.deposit{value: msg.value}();
        shares = WETH_VAULT.deposit(msg.value, receiver);
        if (shares == 0) revert ZeroShares();

        emit DepositedETHToVault(msg.sender, receiver, msg.value, shares);
    }

    /// @inheritdoc ILidoLendDepositGateway
    function depositWethToVault(uint256 wethAmount, address receiver) external returns (uint256 shares) {
        if (wethAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroReceiver();

        WETH.safeTransferFrom(msg.sender, address(this), wethAmount);
        shares = WETH_VAULT.deposit(wethAmount, receiver);
        if (shares == 0) revert ZeroShares();

        emit DepositedWETHToVault(msg.sender, receiver, wethAmount, shares);
    }
}
