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

import {IDeleverageHeap} from "./interfaces/IDeleverageHeap.sol";
import {IMarketController} from "./interfaces/IMarketController.sol";
import {IOracle} from "@morpho-blue/src/interfaces/IOracle.sol";

interface IMorphoBlueForkVaultMorpho is IMorpho {
    function deleverage(
        MarketParams memory marketParams,
        uint256 supplyShares,
        address borrower,
        address onBehalf,
        address receiver
    ) external returns (uint256 collateralSeized, uint256 debtCanceled);
}

/// @title MorphoBlueForkERC4626Vault
/// @notice Single-market ERC-4626 wrapper for a Morpho Blue fork market with fallback exit support.
contract MorphoBlueForkERC4626Vault is ERC4626, ReentrancyGuard {
    using MarketParamsLib for MarketParams;
    using SafeERC20 for IERC20;
    using SharesMathLib for uint256;

    error ZeroShares();
    error ZeroAddress();
    error ZeroMorphoSupplyShares();
    error InsufficientCollateralOut(uint256 received, uint256 minimum);
    error InsufficientDeleverageCuts(uint256 coveredDebtAssets, uint256 targetDebtAssets);
    error MaxIterationsExhausted();

    event FallbackExit(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 loanAssets,
        uint256 morphoSupplyShares,
        uint256 collateralSeized,
        uint256 debtCanceled
    );

    event FallbackExitCut(
        address indexed borrower,
        uint256 morphoSupplyShares,
        uint256 collateralSeized,
        uint256 debtCanceled
    );

    IMorphoBlueForkVaultMorpho public immutable MORPHO;
    IDeleverageHeap public immutable DELEVERAGE_HEAP;
    IMarketController public immutable CONTROLLER;
    Id public immutable MARKET_ID;
    IERC20 public immutable COLLATERAL_TOKEN;

    MarketParams internal _marketParams;

    constructor(
        address morpho,
        MarketParams memory marketParams_,
        address controller,
        address deleverageHeap,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC4626(IERC20(marketParams_.loanToken))
    {
        if (
            morpho == address(0) || controller == address(0) || deleverageHeap == address(0)
                || marketParams_.collateralToken == address(0)
        ) {
            revert ZeroAddress();
        }

        MORPHO = IMorphoBlueForkVaultMorpho(morpho);
        DELEVERAGE_HEAP = IDeleverageHeap(deleverageHeap);
        CONTROLLER = IMarketController(controller);
        MARKET_ID = marketParams_.id();
        COLLATERAL_TOKEN = IERC20(marketParams_.collateralToken);
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

    /// @notice Burns vault shares and exits the vault's Morpho supply position through core deleverage.
    /// @dev Collateral is transferred directly by Morpho to `receiver`; the vault does not custody it.
    function fallbackExit(uint256 shares, address receiver, address owner, uint256 minCollateralOut)
        external
        nonReentrant
        returns (uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 morphoSupplyShares;
        (loanAssets, morphoSupplyShares) = previewFallbackExit(shares);
        if (morphoSupplyShares == 0) revert ZeroMorphoSupplyShares();

        address caller = _msgSender();
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _burn(owner, shares);

        if (loanAssets != 0) IERC20(asset()).safeTransfer(receiver, loanAssets);

        (collateralSeized, debtCanceled) = _deleverageFromHeap(morphoSupplyShares, receiver);
        if (collateralSeized < minCollateralOut) revert InsufficientCollateralOut(collateralSeized, minCollateralOut);

        emit FallbackExit(caller, owner, receiver, shares, loanAssets, morphoSupplyShares, collateralSeized, debtCanceled);
    }

    /// @notice Returns the loan assets and Morpho supply shares consumed by `fallbackExit(shares, ...)`.
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

    function _deleverageFromHeap(uint256 morphoSupplyShares, address receiver)
        internal
        returns (uint256 collateralSeized, uint256 debtCanceled)
    {
        uint256 remainingShares = morphoSupplyShares;
        IMarketController.DeleverageHeapConfig memory cfg = CONTROLLER.deleverageHeapConfig(MARKET_ID);

        for (uint256 i = 0; i < cfg.maxIterations; ++i) {
            uint256 remainingDebtAssets = _morphoSupplySharesToAssets(remainingShares);
            if (remainingDebtAssets == 0) return (collateralSeized, debtCanceled);
            if (DELEVERAGE_HEAP.size() == 0) {
                revert InsufficientDeleverageCuts(debtCanceled, debtCanceled + remainingDebtAssets);
            }

            (address top, uint256 topKey) = DELEVERAGE_HEAP.peek();
            uint256 sliceAssets = _computeSliceAssets(top, topKey, cfg.sliceFloorAssets);
            if (sliceAssets > remainingDebtAssets) sliceAssets = remainingDebtAssets;

            uint256 cutSupplyShares = _morphoAssetsToSupplyShares(sliceAssets);
            if (cutSupplyShares == 0) revert ZeroMorphoSupplyShares();
            if (cutSupplyShares > remainingShares) cutSupplyShares = remainingShares;

            (uint256 cutCollateralSeized, uint256 cutDebtCanceled) =
                MORPHO.deleverage(_marketParams, cutSupplyShares, top, address(this), receiver);
            remainingShares -= cutSupplyShares;
            collateralSeized += cutCollateralSeized;
            debtCanceled += cutDebtCanceled;

            emit FallbackExitCut(top, cutSupplyShares, cutCollateralSeized, cutDebtCanceled);
        }

        uint256 unresolvedDebtAssets = _morphoSupplySharesToAssets(remainingShares);
        if (unresolvedDebtAssets != 0) {
            revert MaxIterationsExhausted();
        }
    }

    /// @dev Sizes a single cut so the root's heap key drops to (or below) the runner-up's key,
    ///      with a configurable absolute floor on the debt amount. Returns at least `sliceFloor`.
    ///      When the heap has no runner-up (size == 1) or the linear system has no positive
    ///      solution (numerical edge), falls back to `sliceFloor`.
    function _computeSliceAssets(address top, uint256 topKey, uint256 sliceFloor) internal view returns (uint256) {
        uint256 runnerUpKey = DELEVERAGE_HEAP.rootRunnerUpKey();
        if (runnerUpKey == 0) return type(uint256).max; // no constraint from children; cap to remainingDebt later
        if (runnerUpKey >= topKey) return sliceFloor; // root not strictly highest after rounding; floor only

        Position memory pos = MORPHO.position(MARKET_ID, top);
        uint256 topCol = pos.collateral;
        if (pos.borrowShares == 0 || topCol == 0) return sliceFloor;

        (,, uint256 totalBorrowAssets_, uint256 totalBorrowShares_) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(MORPHO)), _marketParams);
        if (totalBorrowAssets_ == 0 || totalBorrowShares_ == 0) return sliceFloor;

        uint256 collateralPrice = IOracle(_marketParams.oracle).price();
        if (collateralPrice == 0) return sliceFloor;

        // Solve: (topKey × topCol − runnerUpKey × topCol) = d × (totalBorrowShares × 1e18 / totalBorrowAssets
        //                                                       − runnerUpKey × 1e36 / collateralPrice)
        // where  sharesCut = d × totalBorrowShares / totalBorrowAssets,
        //        colCut    = d × 1e36           / collateralPrice.
        uint256 numerator = (topKey - runnerUpKey) * topCol;

        uint256 denomT1 = (totalBorrowShares_ * 1e18) / totalBorrowAssets_;
        uint256 denomT2 = (runnerUpKey * 1e36) / collateralPrice;
        if (denomT1 <= denomT2) return sliceFloor; // linear system inverts in extreme regimes
        uint256 denom = denomT1 - denomT2;

        uint256 d = numerator / denom;
        return d > sliceFloor ? d : sliceFloor;
    }

    function _morphoSupplyAssets() internal view returns (uint256) {
        uint256 supplyShares = _morphoSupplyShares();
        if (supplyShares == 0) return 0;

        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(MORPHO)), _marketParams);
        return supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    function _morphoSupplySharesToAssets(uint256 supplyShares) internal view returns (uint256) {
        if (supplyShares == 0) return 0;

        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(MORPHO)), _marketParams);
        return supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    function _morphoAssetsToSupplyShares(uint256 assets) internal view returns (uint256) {
        if (assets == 0) return 0;

        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(MORPHO)), _marketParams);
        return assets.toSharesDown(totalSupplyAssets, totalSupplyShares);
    }

    function _morphoWithdrawableAssets() internal view returns (uint256) {
        uint256 supplyShares = _morphoSupplyShares();
        if (supplyShares == 0) return 0;

        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(MORPHO)), _marketParams);
        uint256 supplyAssets = supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
        uint256 liquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        return Math.min(supplyAssets, liquidity);
    }

    function _morphoSupplyShares() internal view returns (uint256) {
        Position memory position = MORPHO.position(MARKET_ID, address(this));
        return position.supplyShares;
    }
}
