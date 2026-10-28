// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IIrm} from "@lido-lend/src/interfaces/IIrm.sol";
import {Id, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {ErrorsLib} from "@lido-lend/src/libraries/ErrorsLib.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";

import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {IrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/IrmConfigFactory.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {IIrm as IrmIIrm} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IIrm.sol";
import {Id as IrmId, MarketParams as IrmMarketParams} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";

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

    /// @dev Pins open finding ll-aud-01: a factory-valid ceiling config makes accrual overflow, and every repair that
    ///      accrues first reverts too. A fix changes this outcome; update this test with the fix.
    function test_LLAUD01_ceilingConfig_overflowsAccrual_onlyDirectOwnerApplyRecovers() public {
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

    /// @dev Pins open finding ll-aud-02: the admin of a non-factory config raises the market rate after the motion,
    ///      with no new motion. A fix changes this outcome; update this test with the fix.
    function test_LLAUD02_mutableConfig_adminRepricesWithoutMotion() public {
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

    /// @dev Pins open finding ll-aud-02: the admin of a non-factory config makes its getter revert, which halts every
    ///      accruing action and every repair that accrues first. A fix changes this outcome; update this test with
    ///      the fix.
    function test_LLAUD02_revertingGetter_haltsAccrual_onlyDirectOwnerApplyRecovers() public {
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
        Market storage m = _m();
        return IrmMarketParams({
            loanToken: m.params.loanToken,
            collateralToken: m.params.collateralToken,
            oracle: m.params.oracle,
            irm: m.params.irm,
            lltv: m.params.lltv
        });
    }
}
