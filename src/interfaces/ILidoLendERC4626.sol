// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @notice Single-market ERC-4626 lender vault over a LidoLend (Morpho Blue fork) market: the standard
///         ERC-4626 surface plus the griefing-resistant fallback exit and the targeted settle. The vault
///         supplies lender deposits into the market and exits illiquid positions by cancelling borrower
///         debt for seized collateral.
interface ILidoLendERC4626 is IERC4626 {
    /// @notice An automatic `fallbackExit` settled its illiquid remainder against the risk queue.
    event FallbackExit(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        uint256 collateralSeized,
        uint256 debtCanceled
    );

    /// @notice A targeted `settle` cut the caller-named borrowers.
    event Settled(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        uint256 collateralSeized,
        uint256 debtCanceled
    );

    error ZeroShares();
    error ZeroAddress();
    error ZeroLidoLend();
    error ZeroController();
    error ZeroLoanToken();
    error ZeroCollateralToken();
    error ZeroMorphoSupplyShares();
    error ExceededBalance(address owner, uint256 requested, uint256 available);
    error EmptyBorrowers();

    /// @notice The market parameters this vault supplies into.
    function marketParams() external view returns (MarketParams memory);

    /// @notice Targeted settlement: cancels `borrowers`' debt in order against `owner`'s supply, paying
    ///         seized collateral to `receiver`. Liquidity-neutral (no redeem leg); each cut is subject to
    ///         the core settle gate. Best-effort, no revert on shortfall.
    function settle(uint256 shares, address[] calldata borrowers, address receiver, address owner)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);

    /// @notice Automatic fallback exit: first redeems whatever ordinary market liquidity covers (paid as
    ///         loan assets), then settles the remainder against the risk queue head-first (paid as seized
    ///         collateral). Best-effort; `maxIterations` caps the borrowers the settle leg cuts
    ///         (`0` uses the default).
    function fallbackExit(uint256 shares, address receiver, address owner, uint256 maxIterations)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);

    /// @notice The loan assets and core supply shares a `fallbackExit` of `shares` would consume.
    function previewFallbackExit(uint256 shares) external view returns (uint256 loanAssets, uint256 morphoSupplyShares);
}
