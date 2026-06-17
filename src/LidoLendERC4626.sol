// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Id, IMorpho, MarketParams, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {
    ILidoLendMarketController as ILidoLendBaseMarketController
} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {SettlementQueueLib} from "./libs/SettlementQueueLib.sol";
import {SlicePolicy} from "./types/SettlementTypes.sol";

/// @dev Off-hook view surface of the controller the vault sizes its exit loop against. Not part of the
///      core `ILidoLendBaseMarketController` interface (which is hooks-only), so the vault reaches these
///      controller-specific views by casting `address(CONTROLLER)`.
interface ISlicePolicyView {
    function slicePolicy() external view returns (SlicePolicy memory);
    function nextSettlementCut() external view returns (address borrower, uint256 sliceAssets);
    function allowedSliceFor(address borrower) external view returns (uint256);
}

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

    event SettlementCut(
        address indexed borrower, uint256 morphoSupplyShares, uint256 collateralSeized, uint256 debtCanceled
    );

    /// @dev Per-call cut bound for the fallback-exit loop (gas safety).
    uint256 internal constant MAX_SETTLEMENT_ITERATIONS = 150;

    IMorpho public MORPHO;
    ILidoLendBaseMarketController public CONTROLLER;
    Id public marketId;
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
        CONTROLLER = ILidoLendBaseMarketController(controller);
        marketId = marketParams_.id();
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
        return Math.min(_ownerAssets(owner), _liquidAssets());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        uint256 liquidAssets = _liquidAssets();

        if (_ownerAssets(owner) <= liquidAssets) return ownerShares;
        return Math.min(ownerShares, convertToShares(liquidAssets));
    }

    /// @dev Owner's full position valued in assets. This is what OZ's `maxWithdraw` means, computed
    ///      directly: the base `maxWithdraw` routes through `maxRedeem`, which this contract overrides,
    ///      so calling `super.maxWithdraw` here would recurse into the override indefinitely.
    function _ownerAssets(address owner) private view returns (uint256) {
        return previewRedeem(balanceOf(owner));
    }

    /// @dev Idle loan assets the vault holds plus what its Morpho position can withdraw right now.
    function _liquidAssets() private view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _morphoWithdrawableAssets();
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

    /// @notice Automatic fallback exit. First pays out as much as ordinary market liquidity covers via a
    ///         normal redeem, then settles the remainder against the controller's risk queue (head first),
    ///         seizing collateral to `receiver`. The caller does not pick the positions. Settling is
    ///         best-effort: whatever fraction is serviced is burned (matching slice of idle loan assets
    ///         paid out), no revert on shortfall.
    /// @dev Redeeming what liquidity covers before settling closes a griefing vector: the core blocks
    ///      `settle` while idle liquidity still covers the amount (`SETTLEMENT_LIQUIDITY_AVAILABLE`), so
    ///      without the redeem an attacker could add idle right before the call and force the whole exit
    ///      to revert. Here that liquidity instead flows to the owner as loan assets.
    ///      Reverts `ZeroMorphoSupplyShares` only if settling is reached with no Morpho position.
    ///      Collateral is transferred directly by Morpho to `receiver`; the vault does not custody it.
    function fallbackExit(uint256 shares, address receiver, address owner)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        // 1. Ordinary path: redeem whatever current liquidity (idle + Morpho-withdrawable) can honour.
        uint256 remaining;
        (sharesBurned, loanAssets, remaining) = _redeemAvailable(shares, receiver, owner);

        // 2. Settle the remainder against the risk queue (collateral to receiver). The redeem above
        //    drained idle, so the core's liquidity gate no longer blocks this settle.
        if (remaining != 0) {
            ExitPlan memory plan = _beginExit(remaining, receiver, owner);
            uint256 morphoSupplyConsumed;
            (collateralSeized, debtCanceled, morphoSupplyConsumed) =
                _settleFromHeap(plan.morphoSupplyTarget, receiver, plan.totalSupplyAssets, plan.totalSupplyShares);
            (uint256 settledShares, uint256 settledLoan) =
                _finishExit(plan, morphoSupplyConsumed, collateralSeized, debtCanceled);
            sharesBurned += settledShares;
            loanAssets += settledLoan;
        }
    }

    /// @notice Targeted exit. Like `fallbackExit` it first pays out what ordinary liquidity covers via a
    ///         normal redeem, then settles the remainder — but the caller supplies the exact `borrowers`
    ///         to settle (in order), using `controller.allowedSliceFor` per borrower instead of the risk
    ///         queue. Settling is best-effort, no revert on shortfall. Redeeming first also closes the
    ///         same liquidity-gate griefing vector described on `fallbackExit`.
    function settle(uint256 shares, address[] calldata borrowers, address receiver, address owner)
        external
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        uint256 remaining;
        (sharesBurned, loanAssets, remaining) = _redeemAvailable(shares, receiver, owner);

        if (remaining != 0) {
            ExitPlan memory plan = _beginExit(remaining, receiver, owner);
            uint256 morphoSupplyConsumed;
            (collateralSeized, debtCanceled, morphoSupplyConsumed) = _settleFromList(
                plan.morphoSupplyTarget, borrowers, receiver, plan.totalSupplyAssets, plan.totalSupplyShares
            );
            (uint256 settledShares, uint256 settledLoan) =
                _finishExit(plan, morphoSupplyConsumed, collateralSeized, debtCanceled);
            sharesBurned += settledShares;
            loanAssets += settledLoan;
        }
    }

    /// @dev Shared first step of `fallbackExit` and `settle`: pay out what ordinary liquidity covers via a
    ///      normal redeem (this also drains idle, so the core's settle liquidity gate cannot block the
    ///      remainder). Returns the shares redeemed, the loan assets paid, and the still-unmet remainder.
    function _redeemAvailable(uint256 shares, address receiver, address owner)
        private
        returns (uint256 redeemedShares, uint256 redeemedAssets, uint256 remaining)
    {
        redeemedShares = Math.min(shares, maxRedeem(owner));
        if (redeemedShares != 0) redeemedAssets = redeem(redeemedShares, receiver, owner);
        remaining = shares - redeemedShares;
    }

    /// @dev Common exit preamble: validate, pull allowance, size the target, snapshot market totals.
    function _beginExit(uint256 shares, address receiver, address owner) private returns (ExitPlan memory plan) {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        address caller = _msgSender();
        if (caller != owner) _spendAllowance(owner, caller, shares);

        plan.morphoSupplyTarget = Math.mulDiv(_morphoSupplyShares(), shares, totalSupply());
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
    function previewFallbackExit(uint256 shares)
        external
        view
        returns (uint256 loanAssets, uint256 morphoSupplyShares)
    {
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

    /// @dev Shared context for one settle call's loop — keeps the `_executeCut` signature
    ///      narrow under via_ir=false (stack pressure with 6 raw args).
    struct CutContext {
        address receiver;
        uint256 totalSupplyAssets;
        uint256 totalSupplyShares;
        uint256 minCutAssets;
    }

    function _settleFromHeap(
        uint256 morphoSupplyShares,
        address receiver,
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares
    ) internal returns (uint256 collateralSeized, uint256 debtCanceled, uint256 sharesConsumed) {
        uint256 remainingShares = morphoSupplyShares;
        uint256 maxIterations = MAX_SETTLEMENT_ITERATIONS;
        CutContext memory ctx = CutContext({
            receiver: receiver,
            totalSupplyAssets: totalSupplyAssets,
            totalSupplyShares: totalSupplyShares,
            minCutAssets: ISlicePolicyView(address(CONTROLLER)).slicePolicy().fallbackMinRequest
        });

        for (uint256 i = 0; i < maxIterations; ++i) {
            if (remainingShares == 0) break;

            (address top, uint256 sliceAssets) = ISlicePolicyView(address(CONTROLLER)).nextSettlementCut();
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

    function _settleFromList(
        uint256 morphoSupplyShares,
        address[] calldata borrowers,
        address receiver,
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares
    ) internal returns (uint256 collateralSeized, uint256 debtCanceled, uint256 sharesConsumed) {
        uint256 remainingShares = morphoSupplyShares;
        CutContext memory ctx = CutContext({
            receiver: receiver,
            totalSupplyAssets: totalSupplyAssets,
            totalSupplyShares: totalSupplyShares,
            minCutAssets: ISlicePolicyView(address(CONTROLLER)).slicePolicy().fallbackMinRequest
        });

        for (uint256 i = 0; i < borrowers.length; ++i) {
            if (remainingShares == 0) break;

            uint256 sliceAssets = ISlicePolicyView(address(CONTROLLER)).allowedSliceFor(borrowers[i]);
            (uint256 iterSupplyShares, uint256 iterCollateralSeized, uint256 iterDebtCanceled) =
                _executeCut(borrowers[i], sliceAssets, remainingShares, ctx);
            if (iterSupplyShares == 0) continue;

            remainingShares -= iterSupplyShares;
            collateralSeized += iterCollateralSeized;
            debtCanceled += iterDebtCanceled;
        }

        sharesConsumed = morphoSupplyShares - remainingShares;
    }

    /// @dev One cut. Sizes the cut via `SettlementQueueLib.effectiveCut` (clamp to the remaining
    ///      exit, drop dust tails the policy would reject), converts to shares, calls the core
    ///      `settle` primitive, emits `SettlementCut`. Zero `iterSupplyShares` means the
    ///      caller should stop / skip.
    function _executeCut(address borrower, uint256 sliceAssets, uint256 remainingShares, CutContext memory ctx)
        internal
        returns (uint256 iterSupplyShares, uint256 iterCollateralSeized, uint256 iterDebtCanceled)
    {
        uint256 remainingExitAssets = remainingShares.toAssetsDown(ctx.totalSupplyAssets, ctx.totalSupplyShares);
        sliceAssets = SettlementQueueLib.effectiveCut(sliceAssets, remainingExitAssets, ctx.minCutAssets);
        if (sliceAssets == 0) return (0, 0, 0);

        iterSupplyShares = sliceAssets.toSharesDown(ctx.totalSupplyAssets, ctx.totalSupplyShares);
        if (iterSupplyShares == 0) return (0, 0, 0);
        if (iterSupplyShares > remainingShares) iterSupplyShares = remainingShares;

        // New core API: settle takes dual assets/shares input (pass shares, assets 0) and orders onBehalf
        // before borrower. We keep shares — the exit loop and ERC4626 accounting are shares-denominated and
        // settle does not return the shares burned, so passing assets would desync `remainingShares`.
        (iterCollateralSeized, iterDebtCanceled) = ILidoLend(address(MORPHO))
            .settle(_marketParams, 0, iterSupplyShares, address(this), borrower, ctx.receiver);

        emit SettlementCut(borrower, iterSupplyShares, iterCollateralSeized, iterDebtCanceled);
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
        uint256 liquidity = Math.saturatingSub(totalSupplyAssets, totalBorrowAssets);
        return Math.min(supplyAssets, liquidity);
    }

    function _morphoSupplyShares() internal view returns (uint256) {
        Position memory position = MORPHO.position(marketId, address(this));
        return position.supplyShares;
    }
}
