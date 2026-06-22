// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

interface IWstETH is IERC20 {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function stETH() external view returns (address);
}

interface ILidoLendVault is IERC20 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @title LidoLendDepositGateway
/// @author Lido Lending contributors.
/// @notice Stateless entry zaps for a WETH/wstETH `LidoLend` market: lenders supply in ETH or WETH
///         (or straight into the vault), borrowers post collateral in stETH. Wrapping convenience
///         lives here so the core stays WETH/wstETH-only.
/// @dev Entry-only: every zap adds value to `onBehalf` / `receiver`, so none of them needs a core
///      authorization — a token approval to this gateway is enough. Holds no funds between
///      transactions, which is also what makes the unlimited constructor approvals to the core and
///      the vault safe: there is never a balance for them to spend outside a zap.
contract LidoLendDepositGateway {
    using SafeERC20 for IERC20;

    // ---
    // ERRORS
    // ---

    /// @notice A zap was passed a zero deposit (`msg.value` or amount argument).
    error ZeroAmount();

    /// @notice A zap was passed the zero address as `onBehalf` / `receiver`, or the constructor as a
    ///         core, token, or vault address.
    error ZeroAddress();

    /// @notice A vault deposit minted zero shares, so the zap would credit `receiver` nothing.
    error ZeroShares();

    /// @notice The vault's underlying asset does not match the market loan token, so it cannot back this
    ///         market's lenders. Checked once at construction.
    error VaultAssetMismatch();

    // ---
    // EVENTS
    // ---

    /// @notice Emitted when stETH is wrapped and posted as collateral. `stEthAmount` is the measured
    ///         stETH received (post rebasing-dust), `wstEthAmount` the wstETH supplied to core.
    event SuppliedCollateralWithStETH(
        address indexed caller, address indexed onBehalf, uint256 stEthAmount, uint256 wstEthAmount
    );

    /// @notice Emitted when ETH is wrapped to WETH and supplied to the market for `onBehalf`.
    event SuppliedWithETH(address indexed caller, address indexed onBehalf, uint256 ethAmount, uint256 shares);

    /// @notice Emitted when WETH is pulled from the caller and supplied to the market for `onBehalf`.
    event SuppliedWithWETH(address indexed caller, address indexed onBehalf, uint256 wethAmount, uint256 shares);

    /// @notice Emitted when ETH is wrapped to WETH and deposited into the vault for `receiver`.
    event DepositedETHToVault(address indexed caller, address indexed receiver, uint256 ethAmount, uint256 shares);

    /// @notice Emitted when WETH is pulled from the caller and deposited into the vault for `receiver`.
    event DepositedWETHToVault(address indexed caller, address indexed receiver, uint256 wethAmount, uint256 shares);

    // ---
    // IMMUTABLES
    // ---

    /// @dev The `LidoLend` core the supply/collateral zaps route into.
    IMorpho public immutable MORPHO;

    /// @dev The market loan token. Lenders' ETH is wrapped into it before supply.
    IWETH public immutable WETH;

    /// @dev The market collateral token. Borrowers' stETH is wrapped into it before `supplyCollateral`.
    IWstETH public immutable WSTETH;

    /// @dev The stETH wrapped into `WSTETH`. Read off `WSTETH.stETH()` at construction.
    IERC20 public immutable STETH;

    /// @dev The ERC-4626 vault the deposit zaps route into. Its asset is the loan token.
    ILidoLendVault public immutable VAULT;

    // ---
    // STORAGE
    // ---

    /// @dev Frozen market identity passed to every `MORPHO.supply` / `supplyCollateral` call.
    MarketParams internal _params;

    // ---
    // CONSTRUCTOR
    // ---

    /// @notice Bind the gateway to one market and its vault, and grant the unlimited approvals the zaps
    ///         rely on: loan and collateral tokens to the core, stETH to wstETH for wrapping, loan token
    ///         to the vault. Reverts on any zero address or a vault whose asset is not the loan token.
    constructor(address morpho, MarketParams memory params, address vault) {
        if (
            morpho == address(0) || params.loanToken == address(0) || params.collateralToken == address(0)
                || vault == address(0)
        ) {
            revert ZeroAddress();
        }
        if (ILidoLendVault(vault).asset() != params.loanToken) revert VaultAssetMismatch();

        MORPHO = IMorpho(morpho);
        WETH = IWETH(params.loanToken);
        WSTETH = IWstETH(params.collateralToken);
        STETH = IERC20(IWstETH(params.collateralToken).stETH());
        VAULT = ILidoLendVault(vault);
        _params = params;

        IERC20(params.loanToken).forceApprove(morpho, type(uint256).max);
        IERC20(params.collateralToken).forceApprove(morpho, type(uint256).max);
        STETH.forceApprove(params.collateralToken, type(uint256).max);
        IERC20(params.loanToken).forceApprove(vault, type(uint256).max);
    }

    // ---
    // ZAPS
    // ---

    /// @notice The market this gateway zaps into.
    function marketParams() external view returns (MarketParams memory) {
        return _params;
    }

    /// @notice Pull stETH from the caller, wrap it to wstETH and post it as collateral for `onBehalf`.
    /// @return wstEthAmount wstETH supplied as collateral.
    function supplyCollateralWithStEth(uint256 stEthAmount, address onBehalf) external returns (uint256 wstEthAmount) {
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
    function supplyWithEth(address onBehalf) external payable returns (uint256 assets, uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();

        WETH.deposit{value: msg.value}();
        (assets, shares) = MORPHO.supply(_params, msg.value, 0, onBehalf, "");

        emit SuppliedWithETH(msg.sender, onBehalf, assets, shares);
    }

    /// @notice Pull WETH from the caller and supply it for `onBehalf`.
    /// @return assets WETH supplied. @return shares Supply shares credited to `onBehalf`.
    function supplyWithWeth(uint256 wethAmount, address onBehalf) external returns (uint256 assets, uint256 shares) {
        if (wethAmount == 0) revert ZeroAmount();
        if (onBehalf == address(0)) revert ZeroAddress();

        IERC20(address(WETH)).safeTransferFrom(msg.sender, address(this), wethAmount);
        (assets, shares) = MORPHO.supply(_params, wethAmount, 0, onBehalf, "");

        emit SuppliedWithWETH(msg.sender, onBehalf, assets, shares);
    }

    /// @notice Wrap `msg.value` to WETH and deposit it into the vault; shares mint to `receiver`.
    /// @return shares Vault shares minted to `receiver`.
    function depositEthToVault(address receiver) external payable returns (uint256 shares) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        WETH.deposit{value: msg.value}();
        shares = VAULT.deposit(msg.value, receiver);
        if (shares == 0) revert ZeroShares();

        emit DepositedETHToVault(msg.sender, receiver, msg.value, shares);
    }

    /// @notice Pull WETH from the caller and deposit it into the vault for `receiver`.
    /// @return shares Vault shares minted to `receiver`.
    function depositWethToVault(uint256 wethAmount, address receiver) external returns (uint256 shares) {
        if (wethAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        IERC20(address(WETH)).safeTransferFrom(msg.sender, address(this), wethAmount);
        shares = VAULT.deposit(wethAmount, receiver);
        if (shares == 0) revert ZeroShares();

        emit DepositedWETHToVault(msg.sender, receiver, wethAmount, shares);
    }
}
