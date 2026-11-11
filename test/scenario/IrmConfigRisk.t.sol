// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {stdError} from "forge-std/StdError.sol";

import {IIrm} from "@lido-lend/src/interfaces/IIrm.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, Market as MorphoMarket, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {ErrorsLib} from "@lido-lend/src/libraries/ErrorsLib.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {AdaptiveCurveConfig} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveConfig.sol";
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {ErrorsLib as IrmErrorsLib} from "@lido-lend-irm/src/adaptive-curve-irm/libraries/ErrorsLib.sol";
import {AdaptiveCurveIrmLib} from "@lido-lend-irm/src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol";
import {OwnerManagerErrors} from "@lido-lend-irm/src/common/OwnerManagerErrors.sol";
import {LinearKinkConfig} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkConfig.sol";
import {LinearKinkIrm} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkIrm.sol";
import {LinearKinkParams} from "@lido-lend-irm/src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {IrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/IrmConfigFactory.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {IIrm as IrmIIrm} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IIrm.sol";
import {
    Id as IrmId,
    Market as IrmMarket,
    MarketParams as IrmMarketParams
} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @dev A curve config that is not the official immutable `AdaptiveCurveConfig`. Its admin can change the returned
///      parameters, or make the getter revert, after a market binds it.
contract MutableCurveConfig {
    error ConfigBroken();

    address public immutable ADMIN;
    AdaptiveCurveParams internal params;
    bool public broken;

    constructor(address admin, AdaptiveCurveParams memory initialParams) {
        ADMIN = admin;
        params = initialParams;
    }

    function setParams(AdaptiveCurveParams memory newParams) external {
        require(msg.sender == ADMIN, "admin only");
        params = newParams;
    }

    function setBroken(bool isBroken) external {
        require(msg.sender == ADMIN, "admin only");
        broken = isBroken;
    }

    function getCurveParams() external view returns (AdaptiveCurveParams memory) {
        if (broken) revert ConfigBroken();
        return params;
    }
}

/// @dev A rate model that returns a flat rate. When armed, its next `borrowRate` call supplies `flashAssets` to the
///      core before it returns, so the supply lands inside the accrual that called it. `exit` withdraws all its shares.
contract ReentrantSupplyIrm {
    using MarketParamsLib for MarketParams;

    ILidoLend public immutable CORE;
    uint256 public immutable RATE;
    MarketParams internal params;
    uint256 public flashAssets;

    constructor(ILidoLend core, MarketParams memory marketParams, uint256 rate) {
        CORE = core;
        params = marketParams;
        RATE = rate;
    }

    function arm(uint256 assets) external {
        flashAssets = assets;
    }

    function borrowRateView(MarketParams memory, MorphoMarket memory) external view returns (uint256) {
        return RATE;
    }

    function borrowRate(MarketParams memory, MorphoMarket memory) external returns (uint256) {
        uint256 assets = flashAssets;
        if (assets != 0) {
            flashAssets = 0;
            IERC20(params.loanToken).approve(address(CORE), assets);
            CORE.supply(params, assets, 0, address(this), "");
        }
        return RATE;
    }

    function exit() external returns (uint256 assets) {
        uint256 shares = CORE.position(params.id(), address(this)).supplyShares;
        (assets,) = CORE.withdraw(params, 0, shares, address(this), address(this));
    }
}

/// @notice Curve configs that the adaptive IRM accepts but that can stop a live market. A config is applied the way
///         the Easy Track motion applies it: accrue under the old curve, then `applyIrmConfig`, in one transaction.
///         Every repair that accrues first fails with the same error as the market. Only the IRM owner's direct
///         `applyIrmConfig` does not accrue, so only it restores accrual.
///
///         The market runs at exactly 100% utilization. The curve error is then 1, so the charged rate is the
///         steepness times the rate at target. No curve here adapts, so each rate is exact.
contract IrmConfigRiskTest is LidoLendSetup {
    using MarketActions for Market;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    /// @dev The validation ceiling for the rate at target, 10000/yr, per second.
    int256 internal constant CEILING_RATE_AT_TARGET = int256(10_000 ether) / int256(365 days);
    /// @dev The validation ceiling for the steepness.
    int256 internal constant CEILING_STEEPNESS = 100e18;
    /// @dev The repair curve: 4%/yr at target, per second.
    int256 internal constant FLAT_RATE_AT_TARGET = int256(4e16) / int256(365 days);
    int256 internal constant FLAT_STEEPNESS = 4e18;

    address internal lender;
    address internal borrower;
    address internal freeHolder;
    address internal keeper;
    address internal configAdmin;

    IrmConfigFactory internal factory;
    address internal flatConfig;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        lender = _actor("lender");
        borrower = _actor("borrower");
        freeHolder = _actor("freeHolder");
        keeper = _actor("keeper");
        configAdmin = _actor("configAdmin");

        factory = new IrmConfigFactory();
        flatConfig = factory.getOrDeployAdaptiveCurveConfig(_flatCurve(FLAT_STEEPNESS));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    // ── ll-aud-01: a validated ceiling config overflows accrual ──

    /// @dev Known issue: a factory-valid ceiling config makes accrual overflow, and every repair that accrues first
    ///      reverts too. Lender exits stop with the market. Without an upgrade of the core proxy or the router proxy,
    ///      only a direct `applyIrmConfig` restores accrual.
    ///      Root cause: the `AdaptiveCurveConfig` validation ceilings allow a rate that is too high. At that rate, one
    ///      week of interest on a large borrow total overflows `toUint128` in `LidoLend._accrueInterest`.
    ///      `IrmRouter.setMarketIrm` accrues through the current route first, so it fails the same way. A repair that
    ///      calls `accrueInterest` before `applyIrmConfig` fails the same way.
    ///      Same cause: a `uint128` overflow in `LidoLend._accrueInterest` when rate, borrow total, and gap together
    ///      are large enough. A direct `applyIrmConfig` does not accrue, so it recovers a config failure only. A routed
    ///      model whose `borrowRate` always reverts has no recovery path short of an upgrade of the core proxy or the
    ///      router proxy.
    ///      A fix changes this outcome; update this test with the fix.
    function test_ceilingConfig_overflowsAccrual_onlyDirectOwnerApplyRecovers() public {
        Market storage m = _m();
        _seedFullUtilization(1e27);
        address ceilingConfig = factory.getOrDeployAdaptiveCurveConfig(_ceilingCurve());
        this.applyConfigLikeMotion(ceilingConfig);

        vm.warp(block.timestamp + 7 days);
        uint256 rate = _fullUseRate(CEILING_STEEPNESS, CEILING_RATE_AT_TARGET);
        uint256 interest = uint256(m.core.market(m.id).totalBorrowAssets).wMulDown(rate.wTaylorCompounded(7 days));
        assertGt(interest, type(uint128).max, "setup: 7 days of interest exceed uint128");

        bytes memory err = bytes(ErrorsLib.MAX_UINT128_EXCEEDED);
        _assertAccruingActionsRevert(err);
        _assertAccrueFirstRepairsRevert(err, ceilingConfig);
        _assertDirectOwnerApplyRecovers();
    }

    // ── ll-aud-02: a mutable config changes rates without a motion ──

    /// @dev The admin of a non-factory config raises the market rate after the motion,
    ///      with no new motion. A fix changes this outcome; update this test with the fix.
    function test_mutableConfig_adminRepricesWithoutMotion() public {
        Market storage m = _m();
        _seedFullUtilization(200 ether);
        MutableCurveConfig config = new MutableCurveConfig(configAdmin, _flatCurve(FLAT_STEEPNESS));
        this.applyConfigLikeMotion(address(config));

        vm.warp(block.timestamp + 1 days);
        assertEq(
            IIrm(m.params.irm).borrowRateView(m.params, m.core.market(m.id)),
            _fullUseRate(FLAT_STEEPNESS, FLAT_RATE_AT_TARGET),
            "setup: the motion's curve prices the market"
        );

        vm.prank(configAdmin);
        config.setParams(_flatCurve(50e18));

        MorphoMarket memory before = m.core.market(m.id);
        uint256 rate = _fullUseRate(50e18, FLAT_RATE_AT_TARGET);
        m.accrueInterest();

        assertEq(
            m.core.market(m.id).totalBorrowAssets,
            before.totalBorrowAssets + uint256(before.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(1 days)),
            "the admin's curve priced the day"
        );
        assertEq(address(_irm().marketCurveConfig(_irmId())), address(config), "binding unchanged");
    }

    /// @dev A mutable config whose getter reverts halts accrual and each repair that accrues first. Only the IRM
    ///      owner or manager can bind such a config.
    function test_revertingGetter_haltsAccrual_onlyDirectOwnerApplyRecovers() public {
        _seedFullUtilization(200 ether);
        MutableCurveConfig config = new MutableCurveConfig(configAdmin, _flatCurve(FLAT_STEEPNESS));
        this.applyConfigLikeMotion(address(config));

        vm.prank(configAdmin);
        config.setBroken(true);
        vm.warp(block.timestamp + 1);

        bytes memory err = abi.encodeWithSelector(MutableCurveConfig.ConfigBroken.selector);
        _assertAccruingActionsRevert(err);
        _assertAccrueFirstRepairsRevert(err, address(config));
        _assertDirectOwnerApplyRecovers();
    }

    // ── A reentrant IRM supplies inside accrual ──

    /// @dev A routed IRM that supplies inside `borrowRate` makes the core charge one interval twice. Only the router
    ///      owner or manager can route a market to such a model.
    function test_reentrantIrmSupplyInAccrual_chargesIntervalTwice() public {
        Market storage m = _m();
        _seedFullUtilization(500 ether);
        _fund(m.loanToken, lender, 500 ether);
        m.vaultDeposit(lender, 500 ether);
        assertEq(m.core.market(m.id).fee, 0, "setup: no protocol fee");

        uint256 rate = uint256(0.5e18) / 365 days;
        uint256 flash = 1_000 ether;
        ReentrantSupplyIrm model = new ReentrantSupplyIrm(m.core, m.params, rate);
        IrmRouter(m.irm).setMarketIrm(_irmParams(), IrmIIrm(address(model)));
        _fund(m.loanToken, address(model), flash);

        uint256 elapsed = 30 days;
        vm.warp(block.timestamp + elapsed);
        MorphoMarket memory before = m.core.market(m.id);
        uint256 growth = rate.wTaylorCompounded(elapsed);
        uint256 nestedInterest = uint256(before.totalBorrowAssets).wMulDown(growth);
        uint256 modelShares = flash.toSharesDown(before.totalSupplyAssets + nestedInterest, before.totalSupplyShares);
        uint256 outerInterest = (before.totalBorrowAssets + nestedInterest).wMulDown(growth);

        model.arm(flash);
        m.core.accrueInterest(m.params);

        MorphoMarket memory afterAccrual = m.core.market(m.id);
        assertEq(
            afterAccrual.totalBorrowAssets,
            before.totalBorrowAssets + nestedInterest + outerInterest,
            "borrowers pay the interval twice"
        );
        assertEq(
            afterAccrual.totalSupplyAssets,
            before.totalSupplyAssets + nestedInterest + flash + outerInterest,
            "the second charge goes to the supply that includes the flash"
        );
        assertEq(m.core.position(m.id, address(model)).supplyShares, modelShares, "flash supply priced after leg 1");

        uint256 expectedOut = modelShares.toAssetsDown(afterAccrual.totalSupplyAssets, afterAccrual.totalSupplyShares);
        uint256 out = model.exit();
        assertEq(out, expectedOut, "model withdraws its share of the second charge");
        assertGt(out, flash, "model takes out more than it put in");
    }

    // ── ApplyIrmConfig does not validate parameters ──

    /// @dev `applyIrmConfig` does not validate curve parameters, so an invalid custom config halts accrual. Only the
    ///      IRM owner or manager can apply a config.
    function test_invalidCurveParams_acceptedByApply_haltAccrual() public {
        _seedFullUtilization(200 ether);
        AdaptiveCurveParams memory invalid = _flatCurve(-1e18);

        vm.expectRevert(bytes(IrmErrorsLib.INVALID_CURVE_STEEPNESS));
        new AdaptiveCurveConfig(invalid);

        MutableCurveConfig config = new MutableCurveConfig(configAdmin, invalid);
        this.applyConfigLikeMotion(address(config));
        assertEq(address(_irm().marketCurveConfig(_irmId())), address(config), "invalid config bound");

        vm.warp(block.timestamp + 1 days);
        bytes memory err = stdError.arithmeticError;
        _assertAccruingActionsRevert(err);
        _assertAccrueFirstRepairsRevert(err, address(config));
        _assertDirectOwnerApplyRecovers();
    }

    // ── Market creation needs the curve config first ──

    /// @dev Specified behaviour: `createMarket` on an adaptive route with no curve config reverts, and it succeeds
    ///      once the config is applied. The NatSpec of `IrmRouter.setMarketIrm` states this revert.
    ///      Root cause: `AdaptiveCurveIrm._borrowRate` reverts with `CONFIG_NOT_SET` when `marketCurveConfig` has no
    ///      entry. The core calls `borrowRate` in `_createMarket` and in each `_accrueInterest` after time has passed.
    ///      Same cause: `LinearKinkIrm._borrowRate` reverts the same way with no kink config. On a live market, a
    ///      route to an unconfigured model fails the probe in `setMarketIrm`.
    function test_createMarket_adaptiveRouteWithoutConfig_reverts() public {
        Market storage m = _m();
        MarketParams memory params = m.params;
        params.lltv = 0.5e18;
        IrmMarketParams memory irmParams = _toIrmParams(params);
        AdaptiveCurveIrm adaptive = new AdaptiveCurveIrm(m.irm, address(this), address(this));
        IrmRouter(m.irm).setMarketIrm(irmParams, IrmIIrm(address(adaptive)));
        Id id = MarketParamsLib.id(params);

        vm.expectRevert(bytes(IrmErrorsLib.CONFIG_NOT_SET));
        m.core.createMarket(params);
        assertEq(m.core.market(id).lastUpdate, 0, "no market created");

        adaptive.applyIrmConfig(irmParams, flatConfig);
        m.core.createMarket(params);

        assertEq(m.core.market(id).lastUpdate, block.timestamp, "market created");
        assertEq(adaptive.rateAtTarget(IrmId.wrap(Id.unwrap(id))), FLAT_RATE_AT_TARGET, "creation seeds the rate");
    }

    // ── The periphery library reads a stale adaptive config ──

    /// @dev Known issue: after the router moves a market to a linear-kink model, `AdaptiveCurveIrmLib.borrowRateView`
    ///      still prices it from the old adaptive config.
    ///      Root cause: `IrmRouter.setMarketIrm` leaves `marketCurveConfig` and `rateAtTarget` in the old
    ///      `AdaptiveCurveIrm`. `AdaptiveCurveIrmLib` uses the IRM address that its caller passes, checks only that a
    ///      config exists, and never reads `IrmRouter.marketIrm`.
    ///      Same cause: `AdaptiveCurveIrmLib.expectedMarketBalances` returns wrong balances for the same market. A
    ///      reroute to another `AdaptiveCurveIrm` instance or to any other model gives the same stale result. Core
    ///      accrual goes through the router, so it uses the live route.
    ///      A fix changes this outcome; update this test with the fix.
    function test_adaptiveLibAfterReroute_returnsStaleRate() public {
        Market storage m = _m();
        _seedFullUtilization(200 ether);
        AdaptiveCurveIrm adaptive = _irm();

        LinearKinkParams memory kink = LinearKinkParams({
            optimalUtilization: 0.8e18,
            baseRate: uint64(uint256(1e16) / 365 days),
            slope1: uint64(uint256(3e16) / 365 days),
            slope2: uint64(uint256(5e17) / 365 days)
        });
        LinearKinkIrm linear = new LinearKinkIrm(address(this), address(this));
        linear.applyIrmConfig(_irmParams(), address(new LinearKinkConfig(kink)));
        IrmRouter(m.irm).setMarketIrm(_irmParams(), IrmIIrm(address(linear)));

        MorphoMarket memory market = m.core.market(m.id);
        assertEq(market.lastUpdate, block.timestamp, "setup: the reroute accrued, so no adaptation is pending");
        int256 frozenRateAtTarget = adaptive.rateAtTarget(_irmId());
        assertGt(frozenRateAtTarget, 0, "setup: the adaptive model priced the market");
        uint256 liveRate = uint256(kink.baseRate) + kink.slope1 + kink.slope2;
        assertEq(IIrm(m.irm).borrowRateView(m.params, market), liveRate, "router prices the kink at 100%");

        uint256 libRate = AdaptiveCurveIrmLib.borrowRateView(
            Id.unwrap(m.id), abi.decode(abi.encode(market), (IrmMarket)), address(adaptive)
        );
        assertEq(libRate, _fullUseRate(4e18, frozenRateAtTarget), "library prices the old adaptive curve");
        assertNotEq(libRate, liveRate, "library rate differs from the live route");
    }

    // ── Idle checkpoints change the stored adaptive rate ──

    /// @dev Known issue: two identical idle markets that accrue on different schedules end the same interval with
    ///      different `rateAtTarget`. Later borrowers start from that rate, until it reaches `minRateAtTarget`.
    ///      Root cause: `LidoLend._accrueInterest` calls the IRM whenever time has passed, also with no borrows.
    ///      `AdaptiveCurveIrm.borrowRate` stores a new `rateAtTarget` at each call. The `wExp` approximation and the
    ///      rounding at each step make the stored rate depend on how the interval is split.
    ///      Same cause: anyone can split an interval with `accrueInterest` or any other accruing action, once per
    ///      block at most. On a market with borrows, the split also changes the stored rate.
    ///      A fix changes this outcome; update this test with the fix.
    function test_idleAccrualSchedule_changesRateAtTarget() public {
        Market storage daily = _m();
        Market storage once = _addMarket(daily.config);
        assertEq(daily.core.market(daily.id).lastUpdate, once.core.market(once.id).lastUpdate, "setup: same start");
        assertEq(daily.core.market(daily.id).totalBorrowAssets, 0, "setup: daily market is idle");
        assertEq(once.core.market(once.id).totalBorrowAssets, 0, "setup: once market is idle");

        for (uint256 day; day < 10; ++day) {
            vm.warp(block.timestamp + 1 days);
            daily.accrueInterest();
        }
        once.accrueInterest();

        assertEq(daily.core.market(daily.id).lastUpdate, once.core.market(once.id).lastUpdate, "same end");
        int256 dailyRate = _adaptiveOf(daily).rateAtTarget(IrmId.wrap(Id.unwrap(daily.id)));
        int256 onceRate = _adaptiveOf(once).rateAtTarget(IrmId.wrap(Id.unwrap(once.id)));
        int256 minRateAtTarget = int256(1e15) / int256(365 days);
        int256 initialRateAtTarget = int256(4e16) / int256(365 days);
        assertGt(onceRate, minRateAtTarget, "setup: decay stays above the floor");
        assertLt(onceRate, initialRateAtTarget, "setup: idle market decays");
        assertNotEq(dailyRate, onceRate, "checkpoint schedule changes the stored rate");
    }

    // ── Ownership moves in one step ──

    /// @dev `IrmRouter.transferOwnership` moves ownership in one call, with no acceptance step. Only the owner can
    ///      call it.
    function test_irmRouterTransferOwnership_singleStep() public {
        IrmRouter router = IrmRouter(_m().irm);
        address wrongTarget = makeAddr("wrongTarget");

        router.transferOwnership(wrongTarget);

        assertEq(router.owner(), wrongTarget, "ownership moved without acceptance");
        vm.expectRevert(bytes(OwnerManagerErrors.NOT_OWNER));
        router.transferOwnership(address(this));
        vm.expectRevert(bytes(OwnerManagerErrors.NOT_OWNER));
        router.setManager(address(this));
    }

    // ── A direct apply does not accrue first ──

    /// @dev Known issue: a direct `applyIrmConfig` with no accrual first makes the next accrual price the whole
    ///      elapsed window at the new curve.
    ///      Root cause: `AdaptiveCurveIrm.applyIrmConfig` and `LinearKinkIrm.applyIrmConfig` change the curve and do
    ///      not accrue. The core prices the full gap since `lastUpdate` at the rate it gets at the next accrual. Only
    ///      `IrmRouter.setMarketIrm` accrues first. A caller of `applyIrmConfig` must call `accrueInterest` first in
    ///      the same transaction to close the window at the old curve.
    ///      Same cause: a rate rise or a rate cut, and the clamp of the stored `rateAtTarget` to the new band. A change
    ///      by the admin of a mutable adaptive config also reprices the open window. Anyone can call `accrueInterest`
    ///      before the apply lands, and the window then gets the old curve.
    ///      A fix changes this outcome; update this test with the fix.
    function test_directApplyWithoutAccrue_pricesElapsedWindowAtNewCurve() public {
        Market storage m = _m();
        _seedFullUtilization(200 ether);
        this.applyConfigLikeMotion(flatConfig);

        uint256 elapsed = 10 days;
        vm.warp(block.timestamp + elapsed);
        MorphoMarket memory before = m.core.market(m.id);
        _irm().applyIrmConfig(_irmParams(), factory.getOrDeployAdaptiveCurveConfig(_flatCurve(50e18)));
        m.accrueInterest();

        uint256 newRate = _fullUseRate(50e18, FLAT_RATE_AT_TARGET);
        uint256 oldRate = _fullUseRate(FLAT_STEEPNESS, FLAT_RATE_AT_TARGET);
        uint256 expected = uint256(before.totalBorrowAssets).wMulDown(newRate.wTaylorCompounded(elapsed));
        assertEq(m.core.market(m.id).totalBorrowAssets, before.totalBorrowAssets + expected, "new curve prices window");
        assertGt(expected, uint256(before.totalBorrowAssets).wMulDown(oldRate.wTaylorCompounded(elapsed)), "not old");
    }

    // ── shared assertions ──

    /// @dev Every action that accrues first reverts with `err`, lender exits included. The vault views run the same
    ///      accrual arithmetic, so the exits fail the same way.
    function _assertAccruingActionsRevert(bytes memory err) internal {
        Market storage m = _m();
        uint256 borrowShares = m.core.position(m.id, borrower).borrowShares;
        uint256 lenderShares = m.vault.balanceOf(lender);

        vm.prank(borrower);
        vm.expectRevert(err);
        m.core.repay(m.params, 0, borrowShares / 2, borrower, "");

        vm.prank(borrower);
        vm.expectRevert(err);
        m.core.borrow(m.params, 1, 0, borrower, borrower);

        vm.prank(freeHolder);
        vm.expectRevert(err);
        m.core.withdrawCollateral(m.params, 1 ether, freeHolder, freeHolder);

        vm.prank(keeper);
        vm.expectRevert(err);
        m.core.liquidate(m.params, borrower, 1 ether, 0, "");

        vm.prank(lender);
        vm.expectRevert(err);
        m.core.supply(m.params, 1 ether, 0, lender, "");

        vm.prank(lender);
        vm.expectRevert(err);
        m.vault.redeem(lenderShares / 2, lender, lender);

        vm.prank(lender);
        vm.expectRevert(err);
        m.vault.fallbackExit(lenderShares, lender, lender, 0);

        vm.expectRevert(err);
        m.core.accrueInterest(m.params);
    }

    /// @dev The motion-shaped repair and a router switch to a working model both accrue under the bound config
    ///      first, so both revert with `err` and the binding stays.
    function _assertAccrueFirstRepairsRevert(bytes memory err, address boundConfig) internal {
        Market storage m = _m();
        IrmMarketParams memory irmParams = _irmParams();

        vm.expectRevert(err);
        this.applyConfigLikeMotion(flatConfig);

        AdaptiveCurveIrm replacement = new AdaptiveCurveIrm(m.irm, address(this), address(this));
        replacement.applyIrmConfig(irmParams, flatConfig);
        vm.expectRevert(err);
        IrmRouter(m.irm).setMarketIrm(irmParams, IrmIIrm(address(replacement)));

        assertEq(address(_irm().marketCurveConfig(_irmId())), boundConfig, "binding unchanged");
    }

    /// @dev The owner's direct apply reads only the new config and does not accrue. The next accrual prices the
    ///      whole stalled interval at the repair curve, and a borrower can repay again.
    function _assertDirectOwnerApplyRecovers() internal {
        Market storage m = _m();
        MorphoMarket memory stalled = m.core.market(m.id);
        _irm().applyIrmConfig(_irmParams(), flatConfig);

        uint256 rate = _fullUseRate(FLAT_STEEPNESS, FLAT_RATE_AT_TARGET);
        uint256 interest =
            uint256(stalled.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(block.timestamp - stalled.lastUpdate));
        m.accrueInterest();
        assertEq(
            m.core.market(m.id).totalBorrowAssets, stalled.totalBorrowAssets + interest, "stalled interval repriced"
        );

        m.repay(borrower, m.core.position(m.id, borrower).borrowShares / 2);
    }

    // ── helpers ──

    /// @dev The Easy Track `ApplyIrmConfig` script order: accrue under the old curve, then apply, atomically. External,
    ///      so a revert of the whole script can be expected.
    function applyConfigLikeMotion(address config) external {
        Market storage m = _m();
        m.core.accrueInterest(m.params);
        _irm().applyIrmConfig(_irmParams(), config);
    }

    /// @dev Lender supplies `supply`, the borrower takes all of it at LTV 0.5, and a debt-free holder keeps 10 tokens
    ///      of collateral.
    function _seedFullUtilization(uint256 supply) internal {
        Market storage m = _m();
        _fund(m.loanToken, lender, supply);
        m.vaultDeposit(lender, supply);

        uint256 collateral = supply * 2 * ORACLE_PRICE_SCALE / m.oracle.price();
        _fund(m.collateralToken, borrower, collateral);
        m.supplyCollateral(borrower, collateral);
        _fund(m.collateralToken, freeHolder, 10 ether);
        m.supplyCollateral(freeHolder, 10 ether);
        m.activateCollateral();
        m.borrow(borrower, m.core.market(m.id).totalSupplyAssets);

        MorphoMarket memory market = m.core.market(m.id);
        assertEq(market.totalBorrowAssets, market.totalSupplyAssets, "setup: utilization is 100%");
    }

    /// @dev The adaptive curve at error 1 is `((steepness - 1) * 1 + 1) * rateAtTarget`.
    function _fullUseRate(int256 steepness, int256 rateAtTarget) internal pure returns (uint256) {
        return uint256(steepness * rateAtTarget / 1e18);
    }

    /// @dev Validation ceilings of `AdaptiveCurveConfig`: steepness 100, rate at target 10000/yr, no adaptation and
    ///      no borrow-rate cap.
    function _ceilingCurve() internal pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: CEILING_STEEPNESS,
            adjustmentSpeed: 0,
            targetUtilization: 0.9e18,
            initialRateAtTarget: CEILING_RATE_AT_TARGET,
            minRateAtTarget: CEILING_RATE_AT_TARGET,
            maxRateAtTarget: CEILING_RATE_AT_TARGET,
            maxBorrowRate: 0
        });
    }

    /// @dev A curve with no adaptation: the rate at target is pinned to `FLAT_RATE_AT_TARGET`.
    function _flatCurve(int256 steepness) internal pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: steepness,
            adjustmentSpeed: 0,
            targetUtilization: 0.9e18,
            initialRateAtTarget: FLAT_RATE_AT_TARGET,
            minRateAtTarget: FLAT_RATE_AT_TARGET,
            maxRateAtTarget: FLAT_RATE_AT_TARGET,
            maxBorrowRate: 0
        });
    }

    function _irm() internal view returns (AdaptiveCurveIrm) {
        return AdaptiveCurveIrm(address(IrmRouter(_m().irm).marketIrm(_irmId())));
    }

    function _irmId() internal view returns (IrmId) {
        return IrmId.wrap(Id.unwrap(_m().id));
    }

    function _irmParams() internal view returns (IrmMarketParams memory) {
        return _toIrmParams(_m().params);
    }

    function _toIrmParams(MarketParams memory params) internal pure returns (IrmMarketParams memory) {
        return IrmMarketParams({
            loanToken: params.loanToken,
            collateralToken: params.collateralToken,
            oracle: params.oracle,
            irm: params.irm,
            lltv: params.lltv
        });
    }

    function _adaptiveOf(Market storage m) internal view returns (AdaptiveCurveIrm) {
        return AdaptiveCurveIrm(address(IrmRouter(m.irm).marketIrm(IrmId.wrap(Id.unwrap(m.id)))));
    }
}
