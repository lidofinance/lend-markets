// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";

import {ILidoLendMarketController} from "./ILidoLendMarketController.sol";

/// @title ILidoLendERC4626
/// @notice Single-market ERC-4626 wrapper over a `LidoLend` (Morpho Blue fork) market. Beyond the standard
///         vault surface it adds settle-based exits — `settle` (targeted) and `fallbackExit` (automatic) —
///         that close the illiquid remainder of a withdrawal against the market's risk queue.
interface ILidoLendERC4626 is IERC4626 {
    // ---
    // ERRORS
    // ---

    /// @notice Thrown when an exit is requested for zero shares.
    error ZeroShares();

    /// @notice Thrown when the seized-collateral receiver is the zero address.
    error ZeroAddress();

    /// @notice Thrown when the LidoLend core address is zero at construction.
    error ZeroLidoLend();

    /// @notice Thrown when the controller address is zero at initialization.
    error ZeroController();

    /// @notice Thrown when the bound controller governs a different market than the vault's.
    error ControllerMarketMismatch();

    /// @notice Thrown when the market's loan token is the zero address at initialization.
    error ZeroLoanToken();

    /// @notice Thrown when the market's collateral token is the zero address at initialization.
    error ZeroCollateralToken();

    /// @notice Thrown when an exit maps to a zero core supply-share budget.
    error ZeroMorphoSupplyShares();

    /// @notice Thrown when a nonzero deposit receives zero core supply shares.
    /// @param assets The deposited assets that mapped to zero core supply shares.
    error ZeroCoreSupplySharesMinted(uint256 assets);

    /// @notice Thrown when the requested exit shares exceed the owner's balance.
    /// @param owner The account whose balance was checked.
    /// @param shares The requested shares.
    /// @param balance The owner's actual balance.
    error ExceededBalance(address owner, uint256 shares, uint256 balance);

    /// @notice Thrown when `settle` is called with an empty borrowers list.
    error EmptyBorrowers();

    /// @notice Thrown when a nonzero-asset deposit would mint zero vault shares.
    /// @param assets The deposited assets that mapped to zero shares.
    error ZeroSharesMinted(uint256 assets);

    // ---
    // EVENTS
    // ---

    /// @notice An automatic `fallbackExit` settled its illiquid remainder against the risk queue.
    /// @param caller The address that called the exit.
    /// @param owner The account whose shares were burned.
    /// @param receiver The recipient of the redeemed assets and seized collateral.
    /// @param sharesBurned Shares burned by the settle leg.
    /// @param collateralSeized Collateral seized from the cut positions.
    /// @param debtCanceled Borrower debt cancelled by the cuts.
    event FallbackExit(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        uint256 collateralSeized,
        uint256 debtCanceled
    );

    /// @notice A targeted `settle` cut the caller-named borrowers.
    /// @param caller The address that called the settle.
    /// @param owner The account whose shares were burned.
    /// @param receiver The recipient of the seized collateral.
    /// @param sharesBurned Shares burned for the settled slice.
    /// @param collateralSeized Collateral seized from the cut positions.
    /// @param debtCanceled Borrower debt cancelled by the cuts.
    event Settled(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        uint256 collateralSeized,
        uint256 debtCanceled
    );

    // ---
    // CONSTANTS / IMMUTABLES
    // ---

    /// @notice Default per-call cut bound for the fallback-exit loop (gas safety); `fallbackExit` callers may
    ///         override it, and passing 0 falls back to this.
    function DEFAULT_MAX_SETTLEMENT_ITERATIONS() external view returns (uint256);

    /// @notice The LidoLend core (Morpho Blue fork) this vault supplies into and settles against.
    function LIDO_LEND() external view returns (ILidoLend);

    /// @notice Id of the market this vault wraps.
    function marketId() external view returns (Id);

    /// @notice The market's policy controller, read for settlement-queue sizing.
    function controller() external view returns (ILidoLendMarketController);

    // ---
    // INITIALIZATION
    // ---

    /// @notice Bind the proxy to one market: cache its params, point at the controller, freeze the
    ///         virtual-share decimals offset, and grant the core an unbounded loan-token allowance so deposits
    ///         can supply without a per-call approval.
    /// @param marketParams_ The market this vault wraps; its loan token becomes the ERC-4626 asset.
    /// @param controller_ The market's policy controller, read for settlement-queue sizing.
    /// @param name_ ERC-20 name of the share token.
    /// @param symbol_ ERC-20 symbol of the share token.
    function initialize(
        MarketParams memory marketParams_,
        address controller_,
        string memory name_,
        string memory symbol_
    ) external;

    // ---
    // READS
    // ---

    /// @notice The wrapped market's params (loan/collateral/oracle/irm/lltv), as cached at init.
    function marketParams() external view returns (MarketParams memory);

    /// @notice Core supply shares the vault acquired through its own operations — the backing that counts for
    ///         `totalAssets` and the settlement budgets. Excludes permissionless core `supply` credits made
    ///         directly to the vault address, and is always `<=` the vault's live core supply-share position.
    function managedSupplyShares() external view returns (uint256);

    // ---
    // SETTLEMENT
    // ---

    /// @notice Targeted settlement: cuts the caller-supplied `borrowers` in order (sizing each via
    ///         `controller.settlementFor`) against the owner's Morpho supply, paying seized collateral to
    ///         `receiver`. Best-effort, no revert on shortfall.
    /// @param shares Vault shares to settle against; bounds the Morpho supply consumed by the cuts.
    /// @param borrowers Positions to cut, in order; each sized via `controller.settlementFor`.
    /// @param receiver Recipient of the seized collateral.
    /// @param owner Account whose shares are burned; the caller must hold its allowance if not the owner.
    /// @return sharesBurned Shares burned for the settled slice.
    /// @return loanAssets Always 0 — a targeted settle pays only seized collateral and withdraws no liquidity.
    /// @return collateralSeized Collateral seized from the cut positions and sent to `receiver`.
    /// @return debtCanceled Borrower debt cancelled by the cuts.
    function settle(uint256 shares, address[] calldata borrowers, address receiver, address owner)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);

    /// @notice Automatic fallback exit. First pays out as much as ordinary market liquidity covers via a
    ///         normal redeem, then settles the remainder against the controller's risk queue (head first),
    ///         seizing collateral to `receiver`. The caller does not pick the positions. Settling is
    ///         best-effort: whatever fraction is serviced is burned, no revert on shortfall.
    /// @param shares Vault shares to exit (redeemed first, then the remainder settled).
    /// @param receiver Recipient of both the redeemed loan assets and the seized collateral.
    /// @param owner Account whose shares are burned; the caller must hold its allowance if not the owner.
    /// @param maxIterations Cap on borrowers the settle leg cuts; 0 uses `DEFAULT_MAX_SETTLEMENT_ITERATIONS`.
    /// @return sharesBurned Total shares burned across the redeem and settle legs.
    /// @return loanAssets Loan assets paid to `receiver` by the redeem leg (the settle leg pays only collateral).
    /// @return collateralSeized Collateral seized from settled positions and sent to `receiver`.
    /// @return debtCanceled Borrower debt cancelled by the settle leg.
    function fallbackExit(uint256 shares, address receiver, address owner, uint256 maxIterations)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
}
