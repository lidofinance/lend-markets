// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Id, IMorpho, MarketParams, Position} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-blue/src/libraries/SharesMathLib.sol";

import {IMarketController} from "./interfaces/IMarketController.sol";
import {IMorphoBlueForkDeleverage} from "./interfaces/IMorphoBlueForkDeleverage.sol";

/// @title MorphoBlueForkERC4626Vault
/// @notice Single-market ERC-4626 wrapper for a Morpho Blue fork market with deleverage exit support.
contract MorphoBlueForkERC4626Vault is ERC4626, ReentrancyGuard {
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;
    using SharesMathLib for uint256;

    error ZeroShares();
    error ZeroAddress();
    error ZeroMorphoSupplyShares();

    // Packed payload for `Deleverage` to avoid stack-too-deep on the emit site under
    // via_ir=false. Indexed fields stay as direct args.
    struct DeleverageLog {
        uint256 sharesRequested;
        uint256 sharesBurned;
        uint256 loanAssets;
        uint256 morphoSupplyShares;
        uint256 collateralSeized;
        uint256 debtCanceled;
    }

    event Deleverage(
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
        address indexed borrower,
        uint256 morphoSupplyShares,
        uint256 collateralSeized,
        uint256 debtCanceled
    );

    IMorpho public immutable MORPHO;
    IMarketController public immutable CONTROLLER;
    Id public immutable MARKET_ID;

    MarketParams internal _marketParams;

    constructor(
        address morpho,
        MarketParams memory marketParams_,
        address controller,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC4626(IERC20(marketParams_.loanToken))
    {
        if (morpho == address(0) || controller == address(0) || marketParams_.collateralToken == address(0)) {
            revert ZeroAddress();
        }

        MORPHO = IMorpho(morpho);
        CONTROLLER = IMarketController(controller);
        MARKET_ID = marketParams_.id();
        _marketParams = marketParams_;

        IERC20(marketParams_.loanToken).forceApprove(morpho, type(uint256).max);
    }

    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner);
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

    /// @notice Best-effort deleverage exit. Burns up to `shares` vault shares; whatever fraction
    ///         of the target is actually serviced is burned (matching slice of idle loan assets
    ///         paid out). No revert on shortfall.
    /// @dev Empty `borrowers` walks the controller's heap (head first). Non-empty iterates the
    ///      list, using `controller.allowedSliceFor` per borrower.
    ///
    ///      Reverts `ZeroMorphoSupplyShares` when no Morpho position exists to deleverage against
    ///      (precondition failure — distinct from a shortfall mid-loop, which silently returns
    ///      the consumed fraction).
    ///
    ///      `loanAssets` rounds down via `Math.mulDiv`; the dust accrues to remaining shareholders.
    ///      Collateral is transferred directly by Morpho to `receiver`; the vault does not custody it.
    function deleverage(uint256 shares, address[] calldata borrowers, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        address caller = _msgSender();
        if (caller != owner) _spendAllowance(owner, caller, shares);

        uint256 morphoSupplyConsumed;
        {
            (uint256 loanAssetsTarget, uint256 morphoSupplyTarget) = previewDeleverage(shares);
            if (morphoSupplyTarget == 0) revert ZeroMorphoSupplyShares();

            (uint256 totalSupplyAssets, uint256 totalSupplyShares) = _marketSupplyTotals();
            (collateralSeized, debtCanceled, morphoSupplyConsumed) = borrowers.length == 0
                ? _deleverageFromHeap(morphoSupplyTarget, receiver, totalSupplyAssets, totalSupplyShares)
                : _deleverageFromList(morphoSupplyTarget, borrowers, receiver, totalSupplyAssets, totalSupplyShares);

            sharesBurned = morphoSupplyConsumed >= morphoSupplyTarget
                ? shares
                : Math.mulDiv(shares, morphoSupplyConsumed, morphoSupplyTarget);
            loanAssets = morphoSupplyConsumed >= morphoSupplyTarget
                ? loanAssetsTarget
                : Math.mulDiv(loanAssetsTarget, morphoSupplyConsumed, morphoSupplyTarget);
        }

        if (sharesBurned != 0) _burn(owner, sharesBurned);
        if (loanAssets != 0) IERC20(asset()).safeTransfer(receiver, loanAssets);

        // slither-disable-next-line uninitialized-local
        DeleverageLog memory log;
        log.sharesRequested = shares;
        log.sharesBurned = sharesBurned;
        log.loanAssets = loanAssets;
        log.morphoSupplyShares = morphoSupplyConsumed;
        log.collateralSeized = collateralSeized;
        log.debtCanceled = debtCanceled;
        _emitDeleverage(caller, owner, receiver, log);
    }

    function _emitDeleverage(address caller, address owner, address receiver, DeleverageLog memory log) internal {
        emit Deleverage(
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

    /// @notice Returns the loan assets and Morpho supply shares consumed by `deleverage(shares, ...)`.
    /// @dev `view`, but result tracks the current block's accrued totals. If blocks pass between
    ///      this call and the matching `deleverage` transaction the numbers may shift slightly;
    ///      the on-chain pro-rate is recomputed at execution time so the actual burn matches live state.
    function previewDeleverage(uint256 shares) public view returns (uint256 loanAssets, uint256 morphoSupplyShares) {
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
        uint256 maxIterations = CONTROLLER.deleverageConfig(MARKET_ID).maxIterations;
        CutContext memory ctx = CutContext({
            receiver: receiver,
            totalSupplyAssets: totalSupplyAssets,
            totalSupplyShares: totalSupplyShares
        });

        for (uint256 i = 0; i < maxIterations; ++i) {
            if (remainingShares == 0) break;

            (address top, uint256 sliceAssets) = CONTROLLER.nextDeleverageCut(MARKET_ID);
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
            receiver: receiver,
            totalSupplyAssets: totalSupplyAssets,
            totalSupplyShares: totalSupplyShares
        });

        for (uint256 i = 0; i < borrowers.length; ++i) {
            if (remainingShares == 0) break;

            uint256 sliceAssets = CONTROLLER.allowedSliceFor(MARKET_ID, borrowers[i]);
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

        (iterCollateralSeized, iterDebtCanceled) = IMorphoBlueForkDeleverage(address(MORPHO))
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
