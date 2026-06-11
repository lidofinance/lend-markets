// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Id, IMorpho, MarketParams, Position} from "@lido-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@lido-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-blue/src/libraries/SharesMathLib.sol";

import {ILidoBlueMarketController} from "@lido-blue/src/interfaces/ILidoBlueMarketController.sol";
import {ILidoBlue} from "@lido-blue/src/interfaces/ILidoBlue.sol";

/// @title LidoBlueERC4626
/// @notice Single-market ERC-4626 wrapper for a Morpho Blue fork market with deleverage exit support.
/// @dev    Assumes `asset()` and the market's collateral token are standard ERC-20s without transfer
///         callbacks (no ERC-777 `tokensToSend`, no ERC-1363 `transferAndCall`). Adding a market with
///         a callback-bearing loan or collateral token invalidates the reentrancy analysis here.
contract LidoBlueERC4626 layout at erc7201("lido.lending.storage.LidoBlueERC4626")
    is
    Initializable,
    ERC4626Upgradeable
{
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;
    using SharesMathLib for uint256;

    error ZeroShares();
    error ZeroAddress();
    error ZeroMorphoSupplyShares();

    // Packed payload for `FallbackExit` to avoid stack-too-deep on the emit site under
    // via_ir=false. Indexed fields stay as direct args.
    struct FallbackExitLog {
        uint256 sharesRequested;
        uint256 sharesBurned;
        uint256 loanAssets;
        uint256 morphoSupplyShares;
        uint256 collateralSeized;
        uint256 debtCanceled;
    }

    event FallbackExit(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 sharesRequested,
        uint256 sharesBurned,
        uint256 loanAssets,
        uint256 morphoSupplyShares,
        uint256 collateralSeized,
        uint256 debtCanceled
    );

    event DeleverageCut(
        address indexed borrower, uint256 morphoSupplyShares, uint256 collateralSeized, uint256 debtCanceled
    );

    /// @dev Per-call cut bound for the fallback-exit loop (gas safety). Was a controller config field.
    uint256 internal constant MAX_DELEVERAGE_ITERATIONS = 100;

    IMorpho public MORPHO;
    ILidoBlueMarketController public CONTROLLER;
    Id public MARKET_ID;
    MarketParams internal _marketParams;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address morpho,
        MarketParams memory marketParams_,
        address controller,
        string memory name_,
        string memory symbol_
    ) external initializer {
        if (
            morpho == address(0) || controller == address(0) || marketParams_.loanToken == address(0)
                || marketParams_.collateralToken == address(0)
        ) {
            revert ZeroAddress();
        }

        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(marketParams_.loanToken));

        MORPHO = IMorpho(morpho);
        CONTROLLER = ILidoBlueMarketController(controller);
        MARKET_ID = marketParams_.id();
        _marketParams = marketParams_;

        IERC20(marketParams_.loanToken).forceApprove(morpho, type(uint256).max);
    }

    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _morphoSupplyAssets();
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return
            Math.min(super.maxWithdraw(owner), IERC20(asset()).balanceOf(address(this)) + _morphoWithdrawableAssets());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        uint256 liquidAssets = IERC20(asset()).balanceOf(address(this)) + _morphoWithdrawableAssets();

        if (super.maxWithdraw(owner) <= liquidAssets) return ownerShares;
        return Math.min(ownerShares, convertToShares(liquidAssets));
    }

    /// @dev Shared plan for one exit: the preview target + live market totals, bundled to keep the
    ///      `_beginExit` / `_finishExit` signatures narrow under via_ir=false.
    struct ExitPlan {
        uint256 shares;
        address owner;
        address receiver;
        uint256 morphoSupplyTarget;
        uint256 totalSupplyAssets;
        uint256 totalSupplyShares;
    }

    /// @notice Automatic fallback exit. Walks the controller's risk queue (head first) and deleverages
    ///         borrowers until up to `shares` worth of the owner's position is freed — the caller does
    ///         not pick the positions. Best-effort: whatever fraction is serviced is burned (matching
    ///         slice of idle loan assets paid out), no revert on shortfall.
    /// @dev Reverts `ZeroMorphoSupplyShares` when there is no Morpho position to deleverage against.
    ///      `loanAssets` rounds down via `Math.mulDiv`; the dust accrues to remaining shareholders.
    ///      Collateral is transferred directly by Morpho to `receiver`; the vault does not custody it.
    function fallbackExit(uint256 shares, address receiver, address owner)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        ExitPlan memory plan = _beginExit(shares, receiver, owner);
        uint256 morphoSupplyConsumed;
        (collateralSeized, debtCanceled, morphoSupplyConsumed) =
            _deleverageFromHeap(plan.morphoSupplyTarget, receiver, plan.totalSupplyAssets, plan.totalSupplyShares);
        (sharesBurned, loanAssets) = _finishExit(plan, morphoSupplyConsumed, collateralSeized, debtCanceled);
    }

    /// @notice Targeted exit. Same effect as `fallbackExit`, but the caller supplies the exact
    ///         `borrowers` to deleverage (in order), using `controller.allowedSliceFor` per borrower
    ///         instead of the risk queue. Best-effort, no revert on shortfall.
    function deleverage(uint256 shares, address[] calldata borrowers, address receiver, address owner)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        ExitPlan memory plan = _beginExit(shares, receiver, owner);
        uint256 morphoSupplyConsumed;
        (collateralSeized, debtCanceled, morphoSupplyConsumed) = _deleverageFromList(
            plan.morphoSupplyTarget, borrowers, receiver, plan.totalSupplyAssets, plan.totalSupplyShares
        );
        (sharesBurned, loanAssets) = _finishExit(plan, morphoSupplyConsumed, collateralSeized, debtCanceled);
    }

    /// @dev Common exit preamble: validate, pull allowance, preview the target, snapshot market totals.
    function _beginExit(uint256 shares, address receiver, address owner) private returns (ExitPlan memory plan) {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        address caller = _msgSender();
        if (caller != owner) _spendAllowance(owner, caller, shares);

        (, plan.morphoSupplyTarget) = previewFallbackExit(shares);
        if (plan.morphoSupplyTarget == 0) revert ZeroMorphoSupplyShares();
        (plan.totalSupplyAssets, plan.totalSupplyShares) = _marketSupplyTotals();

        plan.shares = shares;
        plan.owner = owner;
        plan.receiver = receiver;
    }

    function _finishExit(
        ExitPlan memory plan,
        uint256 morphoSupplyConsumed,
        uint256 collateralSeized,
        uint256 debtCanceled
    ) private returns (uint256 sharesBurned, uint256 loanAssets) {
        sharesBurned = morphoSupplyConsumed >= plan.morphoSupplyTarget
            ? plan.shares
            : Math.mulDiv(plan.shares, morphoSupplyConsumed, plan.morphoSupplyTarget);

        if (sharesBurned != 0) {
            loanAssets = Math.mulDiv(IERC20(asset()).balanceOf(address(this)), sharesBurned, totalSupply());
            _burn(plan.owner, sharesBurned);
            if (loanAssets != 0) IERC20(asset()).safeTransfer(plan.receiver, loanAssets);
        }

        // slither-disable-next-line uninitialized-local
        FallbackExitLog memory log;
        log.sharesRequested = plan.shares;
        log.sharesBurned = sharesBurned;
        log.loanAssets = loanAssets;
        log.morphoSupplyShares = morphoSupplyConsumed;
        log.collateralSeized = collateralSeized;
        log.debtCanceled = debtCanceled;
        _emitFallbackExit(_msgSender(), plan.owner, plan.receiver, log);
    }

    function _emitFallbackExit(address caller, address owner, address receiver, FallbackExitLog memory log) internal {
        emit FallbackExit(
            caller,
            owner,
            receiver,
            log.sharesRequested,
            log.sharesBurned,
            log.loanAssets,
            log.morphoSupplyShares,
            log.collateralSeized,
            log.debtCanceled
        );
    }

    /// @notice Returns the loan assets and Morpho supply shares consumed by `fallbackExit(shares, ...)`.
    /// @dev `view`, but result tracks the current block's accrued totals. If blocks pass between
    ///      this call and the matching `fallbackExit` transaction the numbers may shift slightly;
    ///      the on-chain pro-rate is recomputed at execution time so the actual burn matches live state.
    function previewFallbackExit(uint256 shares) public view returns (uint256 loanAssets, uint256 morphoSupplyShares) {
        uint256 totalSupply_ = totalSupply();
        if (shares == 0 || totalSupply_ == 0) return (0, 0);

        loanAssets = Math.mulDiv(IERC20(asset()).balanceOf(address(this)), shares, totalSupply_);
        morphoSupplyShares = Math.mulDiv(_morphoSupplyShares(), shares, totalSupply_);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        if (assets != 0) MORPHO.supply(_marketParams, assets, 0, address(this), "");
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _ensureIdleAssets(assets);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _ensureIdleAssets(uint256 assets) internal {
        uint256 idleAssets = IERC20(asset()).balanceOf(address(this));
        if (idleAssets < assets) MORPHO.withdraw(_marketParams, assets - idleAssets, 0, address(this), address(this));
    }

    /// @dev Shared context for one deleverage call's loop — keeps the `_executeCut` signature
    ///      narrow under via_ir=false (stack pressure with 6 raw args).
    struct CutContext {
        address receiver;
        uint256 totalSupplyAssets;
        uint256 totalSupplyShares;
    }

    function _deleverageFromHeap(
        uint256 morphoSupplyShares,
        address receiver,
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares
    ) internal returns (uint256 collateralSeized, uint256 debtCanceled, uint256 sharesConsumed) {
        uint256 remainingShares = morphoSupplyShares;
        uint256 maxIterations = MAX_DELEVERAGE_ITERATIONS;
        CutContext memory ctx = CutContext({
            receiver: receiver, totalSupplyAssets: totalSupplyAssets, totalSupplyShares: totalSupplyShares
        });

        for (uint256 i = 0; i < maxIterations; ++i) {
            if (remainingShares == 0) break;

            (address top, uint256 sliceAssets) = CONTROLLER.nextDeleverageCut();
            if (top == address(0)) break;

            (uint256 iterSupplyShares, uint256 iterCollateralSeized, uint256 iterDebtCanceled) =
                _executeCut(top, sliceAssets, remainingShares, ctx);
            if (iterSupplyShares == 0) break;

            remainingShares -= iterSupplyShares;
            collateralSeized += iterCollateralSeized;
            debtCanceled += iterDebtCanceled;
        }

        sharesConsumed = morphoSupplyShares - remainingShares;
    }

    function _deleverageFromList(
        uint256 morphoSupplyShares,
        address[] calldata borrowers,
        address receiver,
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares
    ) internal returns (uint256 collateralSeized, uint256 debtCanceled, uint256 sharesConsumed) {
        uint256 remainingShares = morphoSupplyShares;
        CutContext memory ctx = CutContext({
            receiver: receiver, totalSupplyAssets: totalSupplyAssets, totalSupplyShares: totalSupplyShares
        });

        for (uint256 i = 0; i < borrowers.length; ++i) {
            if (remainingShares == 0) break;

            uint256 sliceAssets = CONTROLLER.allowedSliceFor(borrowers[i]);
            (uint256 iterSupplyShares, uint256 iterCollateralSeized, uint256 iterDebtCanceled) =
                _executeCut(borrowers[i], sliceAssets, remainingShares, ctx);
            if (iterSupplyShares == 0) continue;

            remainingShares -= iterSupplyShares;
            collateralSeized += iterCollateralSeized;
            debtCanceled += iterDebtCanceled;
        }

        sharesConsumed = morphoSupplyShares - remainingShares;
    }

    /// @dev One cut. Clamps `sliceAssets` to remaining debt, converts to shares, calls the core
    ///      single-borrower primitive, emits `DeleverageCut`. Zero `iterSupplyShares` means the
    ///      caller should stop / skip.
    function _executeCut(address borrower, uint256 sliceAssets, uint256 remainingShares, CutContext memory ctx)
        internal
        returns (uint256 iterSupplyShares, uint256 iterCollateralSeized, uint256 iterDebtCanceled)
    {
        if (sliceAssets == 0) return (0, 0, 0);

        uint256 remainingDebtAssets = remainingShares.toAssetsDown(ctx.totalSupplyAssets, ctx.totalSupplyShares);
        if (sliceAssets > remainingDebtAssets) sliceAssets = remainingDebtAssets;

        iterSupplyShares = sliceAssets.toSharesDown(ctx.totalSupplyAssets, ctx.totalSupplyShares);
        if (iterSupplyShares == 0) return (0, 0, 0);
        if (iterSupplyShares > remainingShares) iterSupplyShares = remainingShares;

        (iterCollateralSeized, iterDebtCanceled) = ILidoBlue(address(MORPHO))
            .deleverage(_marketParams, iterSupplyShares, borrower, address(this), ctx.receiver);

        emit DeleverageCut(borrower, iterSupplyShares, iterCollateralSeized, iterDebtCanceled);
    }

    function _marketSupplyTotals() internal view returns (uint256 totalSupplyAssets, uint256 totalSupplyShares) {
        (totalSupplyAssets, totalSupplyShares,,) = MorphoBalancesLib.expectedMarketBalances(MORPHO, _marketParams);
    }

    function _morphoSupplyAssets() internal view returns (uint256) {
        uint256 supplyShares = _morphoSupplyShares();
        if (supplyShares == 0) return 0;
        (uint256 totalSupplyAssets, uint256 totalSupplyShares) = _marketSupplyTotals();
        return supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    function _morphoWithdrawableAssets() internal view returns (uint256) {
        uint256 supplyShares = _morphoSupplyShares();
        if (supplyShares == 0) return 0;

        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            MorphoBalancesLib.expectedMarketBalances(MORPHO, _marketParams);
        uint256 supplyAssets = supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
        uint256 liquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        return Math.min(supplyAssets, liquidity);
    }

    function _morphoSupplyShares() internal view returns (uint256) {
        Position memory position = MORPHO.position(MARKET_ID, address(this));
        return position.supplyShares;
    }
}
