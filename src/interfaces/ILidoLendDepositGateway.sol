// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @notice Minimal WETH surface the gateway uses: wrap ETH into WETH.
interface IWETH is IERC20 {
    /// @notice Wrap the attached ETH (`msg.value`) into WETH 1:1.
    function deposit() external payable;
}

/// @notice Minimal wstETH surface the gateway uses: wrap stETH and read its address.
interface IWstETH is IERC20 {
    /// @notice Wrap `stETHAmount` of stETH into wstETH.
    /// @param stETHAmount stETH to wrap.
    /// @return The wstETH minted.
    function wrap(uint256 stETHAmount) external returns (uint256);

    /// @notice The stETH token this wstETH wraps.
    /// @return The stETH address.
    function stETH() external view returns (address);
}

/// @title ILidoLendDepositGateway
/// @notice Surface of the WETH/wstETH `LidoLend` deposit gateway: entry zaps that let lenders supply in ETH
///         or WETH (or straight into the vault) and borrowers post stETH collateral, with all wrapping done
///         here so the core stays WETH/wstETH-only.
interface ILidoLendDepositGateway {
    // ---
    // ERRORS
    // ---

    /// @notice A zap was passed a zero deposit (`msg.value` or amount argument).
    error ZeroAmount();

    /// @notice A supply zap was passed the zero address as `onBehalf`.
    error ZeroOnBehalf();

    /// @notice A vault deposit zap was passed the zero address as `receiver`.
    error ZeroReceiver();

    /// @notice A vault deposit minted zero shares, so the zap would credit `receiver` nothing.
    error ZeroShares();

    /// @notice The constructor was passed the zero address as the LidoLend core.
    error ZeroMorpho();

    /// @notice The constructor was passed the zero address as WETH.
    error ZeroWeth();

    /// @notice The constructor was passed the zero address as wstETH.
    error ZeroWstEth();

    /// @notice The constructor was passed the zero address as the vault.
    error ZeroVault();

    /// @notice A supply zap was given a market whose loan token is not the pinned WETH.
    error LoanTokenMismatch();

    /// @notice The collateral zap was given a market whose collateral token is not the pinned wstETH.
    error CollateralTokenMismatch();

    /// @notice The vault's underlying asset is not WETH, so it cannot back the gateway's lenders. Checked once
    ///         at construction.
    error VaultAssetMismatch();

    // ---
    // EVENTS
    // ---

    /// @notice Emitted when stETH is wrapped and posted as collateral.
    /// @param caller The address that called the zap.
    /// @param onBehalf The address credited the collateral.
    /// @param stEthAmount The measured stETH received (post rebasing-dust).
    /// @param wstEthAmount The wstETH supplied to the core.
    event SuppliedCollateralWithStETH(
        address indexed caller, address indexed onBehalf, uint256 stEthAmount, uint256 wstEthAmount
    );

    /// @notice Emitted when ETH is wrapped to WETH and supplied to the market.
    /// @param caller The address that called the zap.
    /// @param onBehalf The address credited the supply.
    /// @param ethAmount The ETH wrapped and supplied.
    /// @param shares Supply shares credited to `onBehalf`.
    event SuppliedWithETH(address indexed caller, address indexed onBehalf, uint256 ethAmount, uint256 shares);

    /// @notice Emitted when WETH is pulled from the caller and supplied to the market.
    /// @param caller The address that called the zap.
    /// @param onBehalf The address credited the supply.
    /// @param wethAmount The WETH supplied.
    /// @param shares Supply shares credited to `onBehalf`.
    event SuppliedWithWETH(address indexed caller, address indexed onBehalf, uint256 wethAmount, uint256 shares);

    /// @notice Emitted when ETH is wrapped to WETH and deposited into the vault.
    /// @param caller The address that called the zap.
    /// @param receiver The address credited the vault shares.
    /// @param ethAmount The ETH wrapped and deposited.
    /// @param shares Vault shares minted to `receiver`.
    event DepositedETHToVault(address indexed caller, address indexed receiver, uint256 ethAmount, uint256 shares);

    /// @notice Emitted when WETH is pulled from the caller and deposited into the vault.
    /// @param caller The address that called the zap.
    /// @param receiver The address credited the vault shares.
    /// @param wethAmount The WETH deposited.
    /// @param shares Vault shares minted to `receiver`.
    event DepositedWETHToVault(address indexed caller, address indexed receiver, uint256 wethAmount, uint256 shares);

    // ---
    // IMMUTABLES
    // ---

    /// @notice The `LidoLend` core the supply/collateral zaps route into.
    /// @return The Morpho core contract.
    function MORPHO() external view returns (IMorpho);

    /// @notice The market loan token; lenders' ETH is wrapped into it before supply.
    /// @return The WETH token.
    function WETH() external view returns (IWETH);

    /// @notice The market collateral token; borrowers' stETH is wrapped into it before `supplyCollateral`.
    /// @return The wstETH token.
    function WSTETH() external view returns (IWstETH);

    /// @notice The stETH wrapped into `WSTETH`.
    /// @return The stETH token.
    function STETH() external view returns (IERC20);

    /// @notice The LidoLend WETH vault the deposit zaps route into; its asset is the loan token (WETH).
    /// @return The WETH vault.
    function WETH_VAULT() external view returns (IERC4626);

    // ---
    // ZAPS
    // ---

    /// @notice Pull stETH from the caller, wrap it to wstETH and post it as collateral for `onBehalf`.
    /// @param params The WETH/wstETH market to post collateral into.
    /// @param stEthAmount stETH to pull and wrap.
    /// @param onBehalf Address credited the collateral.
    /// @return wstEthAmount wstETH supplied as collateral.
    function supplyCollateralWithStEth(MarketParams calldata params, uint256 stEthAmount, address onBehalf)
        external
        returns (uint256 wstEthAmount);

    /// @notice Wrap `msg.value` to WETH and supply it for `onBehalf`.
    /// @param params The WETH/wstETH market to supply into.
    /// @param onBehalf Address credited the supply.
    /// @return assets WETH supplied.
    /// @return shares Supply shares credited to `onBehalf`.
    function supplyWithEth(MarketParams calldata params, address onBehalf)
        external
        payable
        returns (uint256 assets, uint256 shares);

    /// @notice Pull `wethAmount` of WETH from the caller and supply it for `onBehalf`.
    /// @param params The WETH/wstETH market to supply into.
    /// @param wethAmount WETH to pull and supply.
    /// @param onBehalf Address credited the supply.
    /// @return assets WETH supplied.
    /// @return shares Supply shares credited to `onBehalf`.
    function supplyWithWeth(MarketParams calldata params, uint256 wethAmount, address onBehalf)
        external
        returns (uint256 assets, uint256 shares);

    /// @notice Wrap `msg.value` to WETH and deposit it into the vault for `receiver`.
    /// @param receiver Address credited the vault shares.
    /// @return shares Vault shares minted to `receiver`.
    function depositEthToVault(address receiver) external payable returns (uint256 shares);

    /// @notice Pull `wethAmount` of WETH from the caller and deposit it into the vault for `receiver`.
    /// @param wethAmount WETH to pull and deposit.
    /// @param receiver Address credited the vault shares.
    /// @return shares Vault shares minted to `receiver`.
    function depositWethToVault(uint256 wethAmount, address receiver) external returns (uint256 shares);
}
