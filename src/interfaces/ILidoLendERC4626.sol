// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";

import {ILidoLendMarketController} from "./ILidoLendMarketController.sol";

/// @title ILidoLendERC4626
/// @notice Single-market ERC-4626 wrapper over a `LidoLend` (Morpho Blue fork) market. Beyond the standard
///         vault surface, `settle` applies caller-ordered personal-policy cuts without withdrawing liquidity,
///         while `fallbackExit` pays available loan assets before settling remaining shares against risk-queue roots.
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

    /// @notice Thrown when a targeted settlement consumes no core supply shares across all requested borrowers,
    ///         or when a fallback exit burns no shares in either leg.
    error NothingSettled();

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

    /// @notice A `fallbackExit` call completed with a positive, possibly partial fill — serviced from market
    ///         liquidity, queue settlement, or both.
    /// @param caller The address that called the exit.
    /// @param owner The account whose shares were burned.
    /// @param receiver The recipient of the liquid-leg loan assets and seized collateral.
    /// @param sharesBurned Shares burned by the whole call — the liquid leg and the settle leg together.
    /// @param sharesSettled Shares burned by the settle leg alone, 0 when liquidity serviced the whole request
    ///        or the queue funded no cut.
    /// @param assetsWithdrawn Loan assets the liquid leg paid out, 0 when the market had no free liquidity or
    ///        the requested shares' floor-rounded value was zero.
    /// @param collateralSeized Collateral seized from the cut positions.
    /// @param debtCanceled Borrower debt cancelled by the cuts.
    event FallbackExit(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 sharesBurned,
        uint256 sharesSettled,
        uint256 assetsWithdrawn,
        uint256 collateralSeized,
        uint256 debtCanceled
    );

    /// @notice A targeted `settle` call completed with a positive, possibly partial fill.
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

    /// @notice Number of settlement cuts a fallback exit makes when the caller does not choose one.
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

    /// @notice Targeted, liquidity-neutral settlement against caller-ordered borrowers. Each cut requires a positive
    ///         personal settlement-LTV slice but not queue-root status; free liquidity remains untouched. A request
    ///         that settles no borrower reverts; budget exhaustion partial-fills.
    /// @param shares Vault shares whose gross pro-rata core-supply claim bounds the cuts.
    /// @param borrowers Positions to cut in order, each sized by its personal settlement-LTV target.
    /// @param receiver Recipient of the seized collateral.
    /// @param owner Account whose shares are burned; the caller must hold its allowance if not the owner.
    /// @return sharesBurned Shares burned for the settled slice.
    /// @return collateralSeized Collateral seized from the cut positions and sent to `receiver`.
    /// @return debtCanceled Borrower debt cancelled by the cuts.
    function settle(uint256 shares, address[] calldata borrowers, address receiver, address owner)
        external
        returns (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled);

    /// @notice Queue-driven fallback exit. The liquid leg burns as many requested shares as current market liquidity
    ///         can service and pays loan assets; the settlement leg applies the remaining share claim to risk-queue
    ///         roots, head first. Queue or iteration exhaustion partial-fills; controller and core errors still revert.
    /// @param shares Vault shares to exit through the liquid leg first and settlement second.
    /// @param receiver Recipient of both the redeemed loan assets and the seized collateral.
    /// @param owner Account whose shares are burned; the caller must hold its allowance if not the owner.
    /// @param maxIterations Cap on settlement-loop iterations; 0 uses `DEFAULT_MAX_SETTLEMENT_ITERATIONS`.
    /// @return sharesBurned Total shares burned across the liquid and settle legs.
    /// @return loanAssets Loan assets paid to `receiver` by the liquid leg (the settle leg pays only collateral).
    /// @return collateralSeized Collateral seized from settled positions and sent to `receiver`.
    /// @return debtCanceled Borrower debt cancelled by the settle leg.
    function fallbackExit(uint256 shares, address receiver, address owner, uint256 maxIterations)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
}
