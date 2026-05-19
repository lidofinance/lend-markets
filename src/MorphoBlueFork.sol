// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {
    Id,
    IMorphoStaticTyping,
    IMorphoBase,
    MarketParams,
    Position,
    Market,
    Authorization,
    Signature
} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {
    IMorphoLiquidateCallback,
    IMorphoRepayCallback,
    IMorphoSupplyCallback,
    IMorphoSupplyCollateralCallback,
    IMorphoFlashLoanCallback
} from "@morpho-blue/src/interfaces/IMorphoCallbacks.sol";
import {IIrm} from "@morpho-blue/src/interfaces/IIrm.sol";
import {IERC20} from "@morpho-blue/src/interfaces/IERC20.sol";
import {IOracle} from "@morpho-blue/src/interfaces/IOracle.sol";

import "@morpho-blue/src/libraries/ConstantsLib.sol";
import {UtilsLib} from "@morpho-blue/src/libraries/UtilsLib.sol";
import {EventsLib} from "@morpho-blue/src/libraries/EventsLib.sol";
import {ErrorsLib} from "@morpho-blue/src/libraries/ErrorsLib.sol";
import {MathLib, WAD} from "@morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "@morpho-blue/src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {SafeTransferLib} from "@morpho-blue/src/libraries/SafeTransferLib.sol";

import {IMarketController} from "./interfaces/IMarketController.sol";

/// @title MorphoBlueForkErrorsLib
/// @notice Error strings added by the forked core, kept in this file to make the upstream diff explicit.
library MorphoBlueForkErrorsLib {
    string internal constant CONTROLLER_MISMATCH = "controller mismatch";
    string internal constant FALLBACK_DISABLED = "fallback disabled";
    string internal constant ZERO_SHARES = "zero shares";
    string internal constant FALLBACK_LIQUIDITY_AVAILABLE = "fallback liquidity available";
    string internal constant FALLBACK_INELIGIBLE = "borrower not fallback-eligible";
    string internal constant FALLBACK_OVER_CAP = "fallback over cap";
}

/// @title MorphoBlueForkEventsLib
/// @notice Events added by the forked core, kept in this file to make the upstream diff explicit.
library MorphoBlueForkEventsLib {
    event MarketControllerSet(Id indexed id, address controller);
    event FallbackEnabled(Id indexed id);

    event FallbackExit(
        Id indexed id,
        address indexed caller,
        address indexed lender,
        address borrower,
        uint256 supplyShares,
        uint256 collateralSeized,
        uint256 debtCanceled
    );
}

/// @title MorphoBlueFork
/// @author Lido Lending contributors. Forked from Morpho Blue by Morpho Labs.
/// @notice Working-name Morpho Blue fork core with optional per-market controllers.
/// @dev `Position`, `Market`, `MarketParams`, and market id derivation stay upstream-shaped.
///      Optional controllers can enforce additional policy through action hooks. The
///      `fallbackExit` extension is core functionality: with no controller it uses the
///      core default rules, and with a controller it can be restricted further by market policy.
contract MorphoBlueFork is IMorphoStaticTyping {
    using MathLib for uint128;
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;

    /* IMMUTABLES */

    /// @inheritdoc IMorphoBase
    bytes32 public immutable DOMAIN_SEPARATOR;

    /* STORAGE */

    /// @inheritdoc IMorphoBase
    address public owner;
    /// @inheritdoc IMorphoBase
    address public feeRecipient;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => mapping(address => Position)) public position;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => Market) public market;
    /// @inheritdoc IMorphoBase
    mapping(address => bool) public isIrmEnabled;
    /// @inheritdoc IMorphoBase
    mapping(uint256 => bool) public isLltvEnabled;
    /// @inheritdoc IMorphoBase
    mapping(address => mapping(address => bool)) public isAuthorized;
    /// @inheritdoc IMorphoBase
    mapping(address => uint256) public nonce;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => MarketParams) public idToMarketParams;

    /* FORK STORAGE */

    /// @notice Optional market controller. Zero address means ordinary Morpho behavior.
    mapping(Id => address) public marketController;
    /// @notice Per-market opt-in for the Lido `fallbackExit` extension. Set only at market creation.
    mapping(Id => bool) public fallbackEnabled;

    /* CONSTRUCTOR */

    /// @param newOwner The new owner of the contract.
    constructor(address newOwner) {
        require(newOwner != address(0), ErrorsLib.ZERO_ADDRESS);

        DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /* MODIFIERS */

    /// @dev Reverts if the caller is not the owner.
    modifier onlyOwner() {
        require(msg.sender == owner, ErrorsLib.NOT_OWNER);
        _;
    }

    /* ONLY OWNER FUNCTIONS */

    /// @inheritdoc IMorphoBase
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != owner, ErrorsLib.ALREADY_SET);

        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /// @inheritdoc IMorphoBase
    function enableIrm(address irm) external onlyOwner {
        require(!isIrmEnabled[irm], ErrorsLib.ALREADY_SET);

        isIrmEnabled[irm] = true;

        emit EventsLib.EnableIrm(irm);
    }

    /// @inheritdoc IMorphoBase
    function enableLltv(uint256 lltv) external onlyOwner {
        require(!isLltvEnabled[lltv], ErrorsLib.ALREADY_SET);
        require(lltv < WAD, ErrorsLib.MAX_LLTV_EXCEEDED);

        isLltvEnabled[lltv] = true;

        emit EventsLib.EnableLltv(lltv);
    }

    /// @inheritdoc IMorphoBase
    function setFee(MarketParams memory marketParams, uint256 newFee) external onlyOwner {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(newFee != market[id].fee, ErrorsLib.ALREADY_SET);
        require(newFee <= MAX_FEE, ErrorsLib.MAX_FEE_EXCEEDED);

        // Accrue interest using the previous fee set before changing it.
        _accrueInterest(marketParams, id);

        // Safe "unchecked" cast.
        market[id].fee = uint128(newFee);

        emit EventsLib.SetFee(id, newFee);
    }

    /// @inheritdoc IMorphoBase
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != feeRecipient, ErrorsLib.ALREADY_SET);

        feeRecipient = newFeeRecipient;

        emit EventsLib.SetFeeRecipient(newFeeRecipient);
    }

    /* MARKET CREATION */

    /// @inheritdoc IMorphoBase
    function createMarket(MarketParams memory marketParams) external onlyOwner {
        _createMarket(marketParams, address(0), false);
    }

    /// @notice Create a market and atomically bind its controller and fallback setting.
    ///         Both are immutable for the life of the market — there is no separate setter.
    /// @param marketParams Market parameters (loan/collateral tokens, oracle, IRM, LLTV).
    /// @param controller Address of the controller. Pass `address(0)` for ordinary Morpho
    ///                   behavior with no controller hooks.
    /// @param fallbackEnabled_ Whether the `fallbackExit` extension is enabled for this market.
    function createMarket(MarketParams memory marketParams, address controller, bool fallbackEnabled_)
        external
        onlyOwner
    {
        _createMarket(marketParams, controller, fallbackEnabled_);
    }

    function _createMarket(MarketParams memory marketParams, address controller, bool fallbackEnabled_) internal {
        Id id = marketParams.id();
        require(isIrmEnabled[marketParams.irm], ErrorsLib.IRM_NOT_ENABLED);
        require(isLltvEnabled[marketParams.lltv], ErrorsLib.LLTV_NOT_ENABLED);
        require(market[id].lastUpdate == 0, ErrorsLib.MARKET_ALREADY_CREATED);

        // Safe "unchecked" cast.
        market[id].lastUpdate = uint128(block.timestamp);
        idToMarketParams[id] = marketParams;
        if (controller != address(0)) {
            require(controller.code.length > 0, ErrorsLib.NO_CODE);
            IMarketController controllerContract = IMarketController(controller);
            require(controllerContract.MARKET() == address(this), MorphoBlueForkErrorsLib.CONTROLLER_MISMATCH);
            require(
                Id.unwrap(controllerContract.MARKET_ID()) == Id.unwrap(id), MorphoBlueForkErrorsLib.CONTROLLER_MISMATCH
            );
            marketController[id] = controller;
            emit MorphoBlueForkEventsLib.MarketControllerSet(id, controller);
        }
        if (fallbackEnabled_) {
            fallbackEnabled[id] = true;
            emit MorphoBlueForkEventsLib.FallbackEnabled(id);
        }

        emit EventsLib.CreateMarket(id, marketParams);

        // Call to initialize the IRM in case it is stateful.
        if (marketParams.irm != address(0)) IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
    }

    /* SUPPLY MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        _hook(
            id,
            IMarketController.HookEvent.Supply,
            abi.encode(
                IMarketController.SupplyHookData({
                    caller: msg.sender, onBehalf: onBehalf, assets: assets, shares: shares
                })
            )
        );

        position[id][onBehalf].supplyShares += shares;
        market[id].totalSupplyShares += shares.toUint128();
        market[id].totalSupplyAssets += assets.toUint128();

        emit EventsLib.Supply(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMorphoSupplyCallback(msg.sender).onMorphoSupply(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /// @inheritdoc IMorphoBase
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesUp(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        else assets = shares.toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);

        _hook(
            id,
            IMarketController.HookEvent.Withdraw,
            abi.encode(
                IMarketController.WithdrawHookData({
                    caller: msg.sender, onBehalf: onBehalf, receiver: receiver, assets: assets, shares: shares
                })
            )
        );

        position[id][onBehalf].supplyShares -= shares;
        market[id].totalSupplyShares -= shares.toUint128();
        market[id].totalSupplyAssets -= assets.toUint128();

        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        emit EventsLib.Withdraw(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /* BORROW MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        _hook(
            id,
            IMarketController.HookEvent.Borrow,
            abi.encode(
                IMarketController.BorrowHookData({
                    caller: msg.sender, onBehalf: onBehalf, receiver: receiver, assets: assets, shares: shares
                })
            )
        );

        position[id][onBehalf].borrowShares += shares.toUint128();
        market[id].totalBorrowShares += shares.toUint128();
        market[id].totalBorrowAssets += assets.toUint128();

        require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);
        require(market[id].totalBorrowAssets <= market[id].totalSupplyAssets, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        emit EventsLib.Borrow(id, msg.sender, onBehalf, receiver, assets, shares);

        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    /// @inheritdoc IMorphoBase
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(assets, shares), ErrorsLib.INCONSISTENT_INPUT);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        _accrueInterest(marketParams, id);

        if (assets > 0) shares = assets.toSharesDown(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        else assets = shares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        _hook(
            id,
            IMarketController.HookEvent.Repay,
            abi.encode(
                IMarketController.RepayHookData({
                    caller: msg.sender, onBehalf: onBehalf, assets: assets, shares: shares
                })
            )
        );

        position[id][onBehalf].borrowShares -= shares.toUint128();
        market[id].totalBorrowShares -= shares.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, assets).toUint128();

        // `assets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Repay(id, msg.sender, onBehalf, assets, shares);

        if (data.length > 0) IMorphoRepayCallback(msg.sender).onMorphoRepay(assets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    /* COLLATERAL MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes calldata data)
        external
    {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        // Don't accrue interest because it's not required and it saves gas.

        _hook(
            id,
            IMarketController.HookEvent.SupplyCollateral,
            abi.encode(
                IMarketController.SupplyCollateralHookData({caller: msg.sender, onBehalf: onBehalf, assets: assets})
            )
        );
        position[id][onBehalf].collateral += assets.toUint128();

        emit EventsLib.SupplyCollateral(id, msg.sender, onBehalf, assets);

        if (data.length > 0) IMorphoSupplyCollateralCallback(msg.sender).onMorphoSupplyCollateral(assets, data);

        IERC20(marketParams.collateralToken).safeTransferFrom(msg.sender, address(this), assets);
    }

    /// @inheritdoc IMorphoBase
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
    {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(assets != 0, ErrorsLib.ZERO_ASSETS);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        _hook(
            id,
            IMarketController.HookEvent.WithdrawCollateral,
            abi.encode(
                IMarketController.WithdrawCollateralHookData({
                    caller: msg.sender,
                    onBehalf: onBehalf,
                    receiver: receiver,
                    assets: assets,
                    borrowerBorrowShares: position[id][onBehalf].borrowShares
                })
            )
        );
        position[id][onBehalf].collateral -= assets.toUint128();

        require(_isHealthy(marketParams, id, onBehalf), ErrorsLib.INSUFFICIENT_COLLATERAL);

        emit EventsLib.WithdrawCollateral(id, msg.sender, onBehalf, receiver, assets);

        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);
    }

    /* LIQUIDATION */

    /// @inheritdoc IMorphoBase
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(UtilsLib.exactlyOneZero(seizedAssets, repaidShares), ErrorsLib.INCONSISTENT_INPUT);

        _accrueInterest(marketParams, id);

        {
            uint256 collateralPrice = IOracle(marketParams.oracle).price();

            require(!_isHealthy(marketParams, id, borrower, collateralPrice), ErrorsLib.HEALTHY_POSITION);

            // The liquidation incentive factor is min(maxLiquidationIncentiveFactor, 1/(1 - cursor*(1 - lltv))).
            uint256 liquidationIncentiveFactor = UtilsLib.min(
                MAX_LIQUIDATION_INCENTIVE_FACTOR,
                WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - marketParams.lltv))
            );

            if (seizedAssets > 0) {
                uint256 seizedAssetsQuoted = seizedAssets.mulDivUp(collateralPrice, ORACLE_PRICE_SCALE);

                repaidShares = seizedAssetsQuoted.wDivUp(liquidationIncentiveFactor)
                    .toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
            } else {
                seizedAssets = repaidShares.toAssetsDown(market[id].totalBorrowAssets, market[id].totalBorrowShares)
                    .wMulDown(liquidationIncentiveFactor).mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
            }
        }
        uint256 repaidAssets = repaidShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);

        // Fire the liquidation action hook after seizedAssets/repaidShares are fully resolved.
        // Either input path reaches this point with both values populated.
        _hook(
            id,
            IMarketController.HookEvent.Liquidate,
            abi.encode(
                IMarketController.LiquidateHookData({
                    caller: msg.sender, borrower: borrower, seizedAssets: seizedAssets, repaidShares: repaidShares
                })
            )
        );

        position[id][borrower].borrowShares -= repaidShares.toUint128();
        market[id].totalBorrowShares -= repaidShares.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, repaidAssets).toUint128();

        position[id][borrower].collateral -= seizedAssets.toUint128();

        uint256 badDebtShares;
        uint256 badDebtAssets;
        if (position[id][borrower].collateral == 0) {
            badDebtShares = position[id][borrower].borrowShares;
            badDebtAssets = UtilsLib.min(
                market[id].totalBorrowAssets,
                badDebtShares.toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares)
            );

            market[id].totalBorrowAssets -= badDebtAssets.toUint128();
            market[id].totalSupplyAssets -= badDebtAssets.toUint128();
            market[id].totalBorrowShares -= badDebtShares.toUint128();
            position[id][borrower].borrowShares = 0;
        }

        // `repaidAssets` may be greater than `totalBorrowAssets` by 1.
        emit EventsLib.Liquidate(
            id, msg.sender, borrower, repaidAssets, repaidShares, seizedAssets, badDebtAssets, badDebtShares
        );

        IERC20(marketParams.collateralToken).safeTransfer(msg.sender, seizedAssets);

        if (data.length > 0) IMorphoLiquidateCallback(msg.sender).onMorphoLiquidate(repaidAssets, data);

        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), repaidAssets);

        return (seizedAssets, repaidAssets);
    }

    /* FALLBACK EXIT */

    /// @notice Per-lender fallback into market collateral when ordinary loan-asset liquidity is insufficient.
    /// @dev Core computes the default oracle-rate collateral amount. A controller, if set, may
    ///      validate the action and update external policy state before core accounting changes.
    function fallbackExit(
        MarketParams memory marketParams,
        uint256 supplyShares,
        address borrower,
        address onBehalf,
        address receiver
    ) external returns (uint256 collateralSeized, uint256 debtCanceled) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(fallbackEnabled[id], MorphoBlueForkErrorsLib.FALLBACK_DISABLED);
        require(supplyShares != 0, MorphoBlueForkErrorsLib.ZERO_SHARES);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        _accrueInterest(marketParams, id);

        debtCanceled = supplyShares.toAssetsDown(market[id].totalSupplyAssets, market[id].totalSupplyShares);
        require(debtCanceled > _availableLiquidity(id), MorphoBlueForkErrorsLib.FALLBACK_LIQUIDITY_AVAILABLE);

        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 borrowSharesToBurn;
        {
            uint256 borrowerRawCollateral = position[id][borrower].collateral;
            uint256 borrowerBorrowAssets = uint256(position[id][borrower].borrowShares)
                .toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
            require(borrowerBorrowAssets != 0, MorphoBlueForkErrorsLib.FALLBACK_INELIGIBLE);
            require(
                _isHealthy(marketParams, id, borrower, collateralPrice), MorphoBlueForkErrorsLib.FALLBACK_INELIGIBLE
            );

            collateralSeized = debtCanceled.mulDivDown(ORACLE_PRICE_SCALE, collateralPrice);
            require(collateralSeized != 0, MorphoBlueForkErrorsLib.FALLBACK_OVER_CAP);

            borrowSharesToBurn = debtCanceled.toSharesUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
            require(
                borrowSharesToBurn <= position[id][borrower].borrowShares, MorphoBlueForkErrorsLib.FALLBACK_OVER_CAP
            );
            require(collateralSeized <= borrowerRawCollateral, MorphoBlueForkErrorsLib.FALLBACK_OVER_CAP);

            _hook(
                id,
                IMarketController.HookEvent.FallbackExit,
                abi.encode(
                    IMarketController.FallbackExitHookData({
                        caller: msg.sender,
                        lender: onBehalf,
                        borrower: borrower,
                        receiver: receiver,
                        assetsToCancel: debtCanceled,
                        borrowerBorrowAssets: borrowerBorrowAssets,
                        borrowerRawCollateral: borrowerRawCollateral,
                        collateralPrice: collateralPrice,
                        collateralSeized: collateralSeized
                    })
                )
            );
        }

        position[id][onBehalf].supplyShares -= supplyShares;
        market[id].totalSupplyShares -= supplyShares.toUint128();
        market[id].totalSupplyAssets = UtilsLib.zeroFloorSub(market[id].totalSupplyAssets, debtCanceled).toUint128();

        position[id][borrower].borrowShares -= borrowSharesToBurn.toUint128();
        market[id].totalBorrowShares -= borrowSharesToBurn.toUint128();
        market[id].totalBorrowAssets = UtilsLib.zeroFloorSub(market[id].totalBorrowAssets, debtCanceled).toUint128();

        position[id][borrower].collateral -= collateralSeized.toUint128();
        require(_isHealthy(marketParams, id, borrower, collateralPrice), MorphoBlueForkErrorsLib.FALLBACK_OVER_CAP);

        emit MorphoBlueForkEventsLib.FallbackExit(
            id, msg.sender, onBehalf, borrower, supplyShares, collateralSeized, debtCanceled
        );

        IERC20(marketParams.collateralToken).safeTransfer(receiver, collateralSeized);
    }

    /* FLASH LOANS */

    /// @inheritdoc IMorphoBase
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, ErrorsLib.ZERO_ASSETS);

        emit EventsLib.FlashLoan(msg.sender, token, assets);

        IERC20(token).safeTransfer(msg.sender, assets);

        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);

        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /* AUTHORIZATION */

    /// @inheritdoc IMorphoBase
    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], ErrorsLib.ALREADY_SET);

        isAuthorized[msg.sender][authorized] = newIsAuthorized;

        emit EventsLib.SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
    }

    /// @inheritdoc IMorphoBase
    function setAuthorizationWithSig(Authorization memory authorization, Signature calldata signature) external {
        /// Do not check whether authorization is already set because the nonce increment is a desired side effect.
        require(block.timestamp <= authorization.deadline, ErrorsLib.SIGNATURE_EXPIRED);
        require(authorization.nonce == nonce[authorization.authorizer]++, ErrorsLib.INVALID_NONCE);

        bytes32 hashStruct = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR, hashStruct));
        address signatory = ecrecover(digest, signature.v, signature.r, signature.s);

        require(signatory != address(0) && authorization.authorizer == signatory, ErrorsLib.INVALID_SIGNATURE);

        emit EventsLib.IncrementNonce(msg.sender, authorization.authorizer, authorization.nonce);

        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;

        emit EventsLib.SetAuthorization(
            msg.sender, authorization.authorizer, authorization.authorized, authorization.isAuthorized
        );
    }

    /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    /* INTEREST MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function accrueInterest(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);

        _hook(
            id,
            IMarketController.HookEvent.AccrueInterest,
            abi.encode(IMarketController.AccrueInterestHookData({caller: msg.sender}))
        );

        _accrueInterest(marketParams, id);
    }

    /// @dev Accrues interest for the given market `marketParams`.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _accrueInterest(MarketParams memory marketParams, Id id) internal {
        uint256 elapsed = block.timestamp - market[id].lastUpdate;
        if (elapsed == 0) return;

        if (marketParams.irm != address(0)) {
            uint256 borrowRate = IIrm(marketParams.irm).borrowRate(marketParams, market[id]);
            uint256 interest = market[id].totalBorrowAssets.wMulDown(borrowRate.wTaylorCompounded(elapsed));
            market[id].totalBorrowAssets += interest.toUint128();
            market[id].totalSupplyAssets += interest.toUint128();

            uint256 feeShares;
            if (market[id].fee != 0) {
                uint256 feeAmount = interest.wMulDown(market[id].fee);
                // The fee amount is subtracted from the total supply in this calculation to compensate for the fact
                // that total supply is already increased by the full interest (including the fee amount).
                feeShares =
                    feeAmount.toSharesDown(market[id].totalSupplyAssets - feeAmount, market[id].totalSupplyShares);
                position[id][feeRecipient].supplyShares += feeShares;
                market[id].totalSupplyShares += feeShares.toUint128();
            }

            emit EventsLib.AccrueInterest(id, borrowRate, interest, feeShares);
        }

        // Safe "unchecked" cast.
        market[id].lastUpdate = uint128(block.timestamp);
    }

    /* HEALTH CHECK */

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower) internal view returns (bool) {
        if (position[id][borrower].borrowShares == 0) return true;

        uint256 collateralPrice = IOracle(marketParams.oracle).price();

        return _isHealthy(marketParams, id, borrower, collateralPrice);
    }

    /// @dev Returns whether the position of `borrower` in the given market `marketParams` with the given
    /// `collateralPrice` is healthy.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    /// @dev Rounds in favor of the protocol, so one might not be able to borrow exactly `maxBorrow` but one unit less.
    function _isHealthy(MarketParams memory marketParams, Id id, address borrower, uint256 collateralPrice)
        internal
        view
        returns (bool)
    {
        uint256 borrowed = uint256(position[id][borrower].borrowShares)
            .toAssetsUp(market[id].totalBorrowAssets, market[id].totalBorrowShares);
        uint256 maxBorrow = uint256(position[id][borrower].collateral).mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)
            .wMulDown(marketParams.lltv);

        return maxBorrow >= borrowed;
    }

    /* CONTROLLER HELPERS */

    /// @dev Single strict-callback dispatch into the controller. ABI-encoded payloads keep the
    ///      core fork surface minimal; the controller decodes per-event in its `on()` handler.
    function _hook(Id id, IMarketController.HookEvent e, bytes memory data) internal {
        address controller = marketController[id];
        if (controller != address(0)) IMarketController(controller).on(id, e, data);
    }

    function _availableLiquidity(Id id) internal view returns (uint256) {
        if (market[id].totalSupplyAssets <= market[id].totalBorrowAssets) return 0;
        return uint256(market[id].totalSupplyAssets) - uint256(market[id].totalBorrowAssets);
    }

    /* STORAGE VIEW */

    /// @inheritdoc IMorphoBase
    function extSloads(bytes32[] calldata slots) external view returns (bytes32[] memory res) {
        uint256 nSlots = slots.length;

        res = new bytes32[](nSlots);

        for (uint256 i; i < nSlots;) {
            bytes32 slot = slots[i++];

            assembly ("memory-safe") {
                mstore(add(res, mul(i, 32)), sload(slot))
            }
        }
    }
}
