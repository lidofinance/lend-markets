// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {ILidoLendMarketController} from "./interfaces/ILidoLendMarketController.sol";

/// @title LidoLendERC4626
/// @notice Single-market ERC-4626 wrapper for a Morpho Blue fork market with settle exit support.
/// @dev    Assumes `asset()` and the market's collateral token are standard ERC-20s without transfer
///         callbacks (no ERC-777 `tokensToSend`, no ERC-1363 `transferAndCall`). Adding a market with
///         a callback-bearing loan or collateral token invalidates the reentrancy analysis here.
contract LidoLendERC4626 layout at erc7201("lido.lending.storage.LidoLendERC4626")
    is
    Initializable,
    ERC4626Upgradeable
{
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;
    using SharesMathLib for uint256;

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

    /// @notice Thrown when the market's loan token is the zero address at initialization.
    error ZeroLoanToken();

    /// @notice Thrown when the market's collateral token is the zero address at initialization.
    error ZeroCollateralToken();

    /// @notice Thrown when an exit reaches its settle leg but the vault holds no Morpho supply shares to cut
    ///         against, so the requested slice maps to a zero supply-share budget.
    error ZeroMorphoSupplyShares();

    /// @notice Thrown when the requested exit shares exceed the owner's balance.
    error ExceededBalance(address owner, uint256 shares, uint256 balance);

    /// @notice Thrown when `settle` is called with an empty borrowers list.
    error EmptyBorrowers();

    // ---
    // EVENTS
    // ---

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

    // ---
    // CONSTANTS
    // ---

    /// @dev Default per-call cut bound for the fallback-exit loop (gas safety). `fallbackExit` callers can
    ///      override it; passing 0 falls back to this.
    uint256 public constant DEFAULT_MAX_SETTLEMENT_ITERATIONS = 150;

    /// @dev Decimals the vault's shares normalize to, like every Morpho vault — independent of the loan
    ///      token's own decimals. The virtual-share offset is `SHARE_DECIMALS - loanTokenDecimals` (floored at 0).
    uint8 private constant SHARE_DECIMALS = 18;

    // ---
    // IMMUTABLES
    // ---

    /// @notice The LidoLend core (Morpho Blue fork) this vault supplies into and settles against.
    ILidoLend public immutable LIDO_LEND;

    // ---
    // STORAGE
    // ---

    /// @notice Id of the market this vault wraps.
    Id public marketId;

    /// @notice The market's policy controller. The vault reads its settlement-queue views to size exit cuts.
    ILidoLendMarketController public controller;

    /// @dev Cached market params (loan/collateral/oracle/irm/lltv) for the core supply, withdraw and settle calls.
    MarketParams internal _marketParams;

    /// @dev Virtual-share decimals offset, `SHARE_DECIMALS - loanTokenDecimals`, frozen at init (see
    /// `_decimalsOffset`).
    uint8 internal _loanDecimalsOffset;

    // ---
    // INITIALIZATION
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address lidoLend) {
        if (lidoLend == address(0)) {
            revert ZeroLidoLend();
        }

        LIDO_LEND = ILidoLend(lidoLend);

        _disableInitializers();
    }

    /// @notice Bind the proxy to one market: cache its params, point at the controller, freeze the
    ///         virtual-share decimals offset, and grant the core an unbounded loan-token allowance so
    ///         deposits can supply without a per-call approval.
    /// @param marketParams_ The market this vault wraps; its loan token becomes the ERC-4626 asset.
    /// @param controller_ The market's policy controller, read for settlement-queue sizing.
    /// @param name_ ERC-20 name of the share token.
    /// @param symbol_ ERC-20 symbol of the share token.
    function initialize(
        MarketParams memory marketParams_,
        address controller_,
        string memory name_,
        string memory symbol_
    ) external initializer {
        if (controller_ == address(0)) {
            revert ZeroController();
        }

        if (marketParams_.loanToken == address(0)) {
            revert ZeroLoanToken();
        }

        if (marketParams_.collateralToken == address(0)) {
            revert ZeroCollateralToken();
        }

        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(marketParams_.loanToken));

        // Offset = SHARE_DECIMALS - loanTokenDecimals (floored at 0), so shares normalize to SHARE_DECIMALS and
        // the virtual-share buffer scales to 10**offset. `decimals()` here returns the underlying's, because
        // the offset is still 0 in storage and has not been folded in yet.
        _loanDecimalsOffset = uint8(Math.saturatingSub(SHARE_DECIMALS, decimals()));

        controller = ILidoLendMarketController(controller_);
        marketId = marketParams_.id();
        _marketParams = marketParams_;

        IERC20(marketParams_.loanToken).forceApprove(address(LIDO_LEND), type(uint256).max);
    }

    // ---
    // GETTERS
    // ---

    /// @notice The wrapped market's params (loan/collateral/oracle/irm/lltv), as cached at init.
    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    // ---
    // OVERRIDES
    // ---

    /// @dev Only the Morpho supply position backs shares. Loan tokens sent directly to the vault
    ///      (donations) are not counted, so they cannot move the share price — this is the donation /
    ///      inflation defense. Stray idle stays inert until a fresh deposit's supply folds it into the position.
    function totalAssets() public view override returns (uint256) {
        uint256 supplyShares = _lidoLendSupplyShares();
        if (supplyShares == 0) return 0;
        (uint256 totalSupplyAssets, uint256 totalSupplyShares) = _marketSupplyTotals();
        return supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    /// @dev Capped by the market's free liquidity, not just the owner's position: the supplied loan token
    ///      can be borrowed out, so withdrawing past available liquidity reverts in the core. The illiquid
    ///      remainder exits through `fallbackExit`.
    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(previewRedeem(balanceOf(owner)), _morphoWithdrawableAssets());
    }

    /// @dev Liquidity cap of `maxWithdraw`, in shares. When the owner's whole position fits in free liquidity
    ///      it returns the exact share balance, avoiding a `convertToShares` round-trip that could round the
    ///      last wei down and strand a share. Otherwise it caps to the shares liquidity covers.
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        uint256 liquidAssets = _morphoWithdrawableAssets();

        return previewRedeem(ownerShares) <= liquidAssets ? ownerShares : convertToShares(liquidAssets);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        if (assets != 0) LIDO_LEND.supply(_marketParams, assets, 0, address(this), "");
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets != 0) LIDO_LEND.withdraw(_marketParams, assets, 0, address(this), address(this));
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev `SHARE_DECIMALS - loanTokenDecimals` (frozen at init): shares normalize to SHARE_DECIMALS like every
    ///      Morpho vault, and the virtual-share buffer scales to 10**offset — defense-in-depth on top of the
    ///      position-only `totalAssets` above, which is the actual donation/inflation defense.
    function _decimalsOffset() internal view override returns (uint8) {
        return _loanDecimalsOffset;
    }

    // ---
    // SETTLEMENT
    // ---

    /// @notice Targeted settlement: cuts the caller-supplied `borrowers` in order (sizing each via
    ///         `controller.settlementFor`) against the owner's Morpho supply, paying seized collateral
    ///         to `receiver`. Best-effort, no revert on shortfall.
    /// @dev Unlike `fallbackExit`, this does NOT redeem ordinary liquidity first — a targeted settle must
    ///      stay liquidity-neutral and only cut the named positions, never draining lender withdraw
    ///      liquidity. It therefore remains subject to the core's `SETTLEMENT_LIQUIDITY_AVAILABLE` gate: a
    ///      cut whose cancelled debt does not exceed the market's ordinary liquidity reverts. Use
    ///      `fallbackExit` for the griefing-resistant lender exit; `settle` is the precise cut.
    ///      Collateral is transferred directly by Morpho to `receiver`; the vault does not custody it.
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
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        if (borrowers.length == 0) revert EmptyBorrowers();
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares > balanceOf(owner)) revert ExceededBalance(owner, shares, balanceOf(owner));

        // The owner's pro-rata slice of the vault's Morpho supply position, in supply shares: the budget the
        // cuts consume.
        uint256 supplyTarget = Math.mulDiv(_lidoLendSupplyShares(), shares, totalSupply());
        if (supplyTarget == 0) revert ZeroMorphoSupplyShares();

        uint256 remaining = supplyTarget;
        for (uint256 i = 0; i < borrowers.length && remaining != 0; ++i) {
            address borrower = borrowers[i];
            (uint256 cutShares, uint256 cutCollateral, uint256 cutDebt) = _settleBorrower(remaining, borrower, receiver);

            remaining -= cutShares;
            collateralSeized += cutCollateral;
            debtCanceled += cutDebt;
        }

        // Burn the shares actually settled (pro-rata when the cuts fell short of the target), spending allowance
        // only for that. loanAssets stays 0 — settle pays the receiver collateral, not loan assets.
        sharesBurned =
            remaining == 0 ? shares : Math.mulDiv(shares, supplyTarget - remaining, supplyTarget, Math.Rounding.Ceil);

        address caller = _msgSender();
        if (sharesBurned != 0) {
            if (caller != owner) _spendAllowance(owner, caller, sharesBurned);
            _burn(owner, sharesBurned);
        }

        emit Settled(caller, owner, receiver, sharesBurned, collateralSeized, debtCanceled);
    }

    function _settleBorrower(uint256 maxSharesToCut, address borrower, address receiver)
        internal
        returns (uint256 cutShares, uint256 collateralSeized, uint256 debtCanceled)
    {
        (, uint256 sliceShares) = controller.settlementFor(borrower);
        if (sliceShares > 0 && maxSharesToCut > 0) {
            cutShares = Math.min(sliceShares, maxSharesToCut);
            (collateralSeized, debtCanceled) =
                LIDO_LEND.settle(_marketParams, 0, cutShares, address(this), borrower, receiver);
        }
    }

    /// @notice Automatic fallback exit. First pays out as much as ordinary market liquidity covers via a
    ///         normal redeem, then settles the remainder against the controller's risk queue (head first),
    ///         seizing collateral to `receiver`. The caller does not pick the positions. Settling is
    ///         best-effort: whatever fraction is serviced is burned, no revert on shortfall.
    /// @dev Redeeming what liquidity covers before settling closes a griefing vector: the core blocks
    ///      `settle` while idle liquidity still covers the amount (`SETTLEMENT_LIQUIDITY_AVAILABLE`), so
    ///      without the redeem an attacker could add idle right before the call and force the whole exit
    ///      to revert. Here that liquidity instead flows to the owner as loan assets.
    ///      Reverts `ZeroMorphoSupplyShares` only if settling is reached with no Morpho position.
    ///      Collateral is transferred directly by Morpho to `receiver`; the vault does not custody it.
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
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares > balanceOf(owner)) revert ExceededBalance(owner, shares, balanceOf(owner));

        // 1. Ordinary path: redeem whatever current liquidity (idle + Morpho-withdrawable) can honour. Draining
        //    idle also stops the core's settle gate from blocking the remainder. OZ redeem burns these shares,
        //    spends allowance, and emits Withdraw for this leg.
        sharesBurned = Math.min(shares, maxRedeem(owner));
        if (sharesBurned != 0) loanAssets = redeem(sharesBurned, receiver, owner);
        uint256 remaining = shares - sharesBurned;
        if (remaining == 0) return (sharesBurned, loanAssets, 0, 0);

        // 2. Settle the remainder against the risk queue, head first (collateral to receiver), up to the owner's
        //    pro-rata supply-share budget for it.
        uint256 supplyTarget = Math.mulDiv(_lidoLendSupplyShares(), remaining, totalSupply());
        if (supplyTarget == 0) revert ZeroMorphoSupplyShares();

        if (maxIterations == 0) maxIterations = DEFAULT_MAX_SETTLEMENT_ITERATIONS;
        uint256 budget = supplyTarget;
        for (uint256 i = 0; i < maxIterations && budget != 0; ++i) {
            (uint256 cutShares, uint256 cutCollateral, uint256 cutDebt) = _settleNextAllowedBorrower(budget, receiver);
            if (cutShares == 0) break;
            budget -= cutShares;
            collateralSeized += cutCollateral;
            debtCanceled += cutDebt;
        }

        // Burn the settled remainder (pro-rata, rounded up so remaining holders aren't diluted) and spend
        // allowance for it; the redeem leg burned its own.
        uint256 settledShares =
            budget == 0 ? remaining : Math.mulDiv(remaining, supplyTarget - budget, supplyTarget, Math.Rounding.Ceil);
        address caller = _msgSender();
        if (settledShares != 0) {
            if (caller != owner) _spendAllowance(owner, caller, settledShares);
            _burn(owner, settledShares);
        }
        sharesBurned += settledShares;

        emit FallbackExit(caller, owner, receiver, settledShares, collateralSeized, debtCanceled);
    }

    function _settleNextAllowedBorrower(uint256 maxSharesToCut, address receiver)
        internal
        returns (uint256 cutShares, uint256 collateralSeized, uint256 debtCanceled)
    {
        (address borrower,, uint256 sliceShares) = controller.nextSettlementBorrower();
        if (borrower != address(0) && sliceShares > 0 && maxSharesToCut > 0) {
            cutShares = Math.min(sliceShares, maxSharesToCut);
            (collateralSeized, debtCanceled) =
                LIDO_LEND.settle(_marketParams, 0, cutShares, address(this), borrower, receiver);
        }
    }

    /// @notice Returns the loan assets and Morpho supply shares consumed by `fallbackExit(shares, ...)`.
    /// @dev `view`, but result tracks the current block's accrued totals. If blocks pass between
    ///      this call and the matching `fallbackExit` transaction the numbers may shift slightly;
    ///      the on-chain pro-rate is recomputed at execution time so the actual burn matches live state.
    function previewFallbackExit(uint256 shares)
        external
        view
        returns (uint256 loanAssets, uint256 morphoSupplyShares)
    {
        uint256 totalSupply_ = totalSupply();
        if (shares == 0 || totalSupply_ == 0) return (0, 0);

        // Redeem leg pays loan assets up to what the Morpho position can withdraw; the rest settles for
        // collateral. Stray idle is uncounted, so it never appears as loan assets.
        loanAssets = Math.min(convertToAssets(shares), _morphoWithdrawableAssets());
        morphoSupplyShares = Math.mulDiv(_lidoLendSupplyShares(), shares, totalSupply_);
    }

    function _marketSupplyTotals() internal view returns (uint256 totalSupplyAssets, uint256 totalSupplyShares) {
        (totalSupplyAssets, totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(LIDO_LEND)), _marketParams);
    }

    function _morphoWithdrawableAssets() internal view returns (uint256) {
        uint256 supplyShares = _lidoLendSupplyShares();
        if (supplyShares == 0) return 0;

        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(LIDO_LEND)), _marketParams);
        uint256 supplyAssets = supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
        uint256 liquidity = Math.saturatingSub(totalSupplyAssets, totalBorrowAssets);
        return Math.min(supplyAssets, liquidity);
    }

    function _lidoLendSupplyShares() internal view returns (uint256 supplyShares) {
        (supplyShares,,) = LIDO_LEND.position(marketId, address(this));
    }
}
