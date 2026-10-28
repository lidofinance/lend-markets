// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IIrm} from "@lido-lend/src/interfaces/IIrm.sol";
import {Id, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {MathLib, WAD} from "@lido-lend/src/libraries/MathLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {AdaptiveCurveConfig} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveConfig.sol";
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {IIrm as IrmIIrm} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IIrm.sol";
import {Id as IrmId, MarketParams as IrmMarketParams} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";

import {PausableUntil} from "../../src/utils/PausableUntil.sol";
import {IPausableUntil} from "../../src/interfaces/IPausableUntil.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice What a paused market does to the people using it. Pause is the broadest lever in the protocol —
///         it rejects every action that reaches the controller, including the ones that reduce risk — so its
///         cost is as important to pin as its reach. The unit suite covers the flag and the role gates; this
///         suite covers the consequences: which user actions stop, what the vault reports while stopped,
///         that the interest clock keeps running while nothing is booked, and that a price crash during a
///         pause becomes realised bad debt the moment it lifts.
///
///         Driven through a `PAUSER_ROLE` holder rather than a real CircuitBreaker. CircuitBreaker's own
///         mechanics, such as the single-use registration and the heartbeat, are covered upstream, by the
///         CircuitBreakerPause scenario, and by the acceptance suite against the deployed instance.
contract PauseLifecycleTest is LidoLendSetup {
    using MarketActions for Market;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    uint256 internal constant LLTV = 0.8e18;
    /// @dev The borrower's LTV when an I-M003 pause starts: healthy, but within reach of LLTV.
    uint256 internal constant BORROWER_LTV = 0.76e18;
    /// @dev Rate at target of the flat curve the IRM owner applies during a pause: 4%/yr, per second.
    int256 internal constant FLAT_RATE_AT_TARGET = int256(4e16) / int256(365 days);
    int256 internal constant FLAT_STEEPNESS = 4e18;

    address internal lender;
    address internal borrower;
    address internal keeper;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        Market storage m = _m();
        lender = _actor("lender");
        _fund(m.loanToken, lender, 2000 ether);
        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 300 ether);
        _fund(m.loanToken, borrower, 1000 ether);
        keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 2000 ether);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender in, borrower at `borrowBps` of its LLTV capacity, collateral matured.
    function _seed(uint256 borrowBps) internal returns (uint256 lenderShares) {
        Market storage m = _m();
        lenderShares = m.vaultDeposit(lender, 1000 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        uint256 maxBorrow = ((100 ether * oraclePrice) / 1e36) * 80 / 100;
        m.borrow(borrower, (maxBorrow * borrowBps) / 10_000);
    }

    // ── Every hooked action stops ──

    function testRevert_Paused_CoreSupplyRejected() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        vm.startPrank(lender);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.supply(m.params, 1 ether, 0, lender, "");
        vm.stopPrank();
    }

    function testRevert_Paused_CoreWithdrawRejected() public {
        Market storage m = _m();
        _seed(5000);
        m.coreSupply(keeper, 100 ether);
        m.pause(1 days);

        vm.prank(keeper);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.withdraw(m.params, 1 ether, 0, keeper, keeper);
    }

    function testRevert_Paused_BorrowRejected() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        vm.prank(borrower);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.borrow(m.params, 1 ether, 0, borrower, borrower);
    }

    /// @dev Notable because repayment reduces risk, yet pause rejects it: a borrower cannot de-lever while
    ///      the market is paused.
    function testRevert_Paused_RepayRejected() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        vm.startPrank(borrower);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.repay(m.params, 0, 1e6, borrower, "");
        vm.stopPrank();
    }

    function testRevert_Paused_SupplyCollateralRejected() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        vm.startPrank(borrower);
        m.collateralToken.approve(address(m.core), type(uint256).max);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.supplyCollateral(m.params, 10 ether, borrower, "");
        vm.stopPrank();
    }

    function testRevert_Paused_WithdrawCollateralRejected() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        vm.prank(borrower);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.withdrawCollateral(m.params, 1 ether, borrower, borrower);
    }

    function testRevert_Paused_AccrueInterestRejected() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.accrueInterest(m.params);
    }

    function testRevert_Paused_SettleRejected() public {
        Market storage m = _m();
        uint256 shares = _seed(9900);
        m.setSettlementLtv(borrower, 0.5e18);
        m.pause(1 days);

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;

        vm.prank(lender);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.vault.settle(shares / 4, borrowers, lender, lender);
    }

    // ── The vault reports itself closed ──

    function test_Paused_VaultLimitsAreAllZero() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        assertEq(m.vault.maxDeposit(lender), 0, "maxDeposit");
        assertEq(m.vault.maxMint(lender), 0, "maxMint");
        assertEq(m.vault.maxWithdraw(lender), 0, "maxWithdraw");
        assertEq(m.vault.maxRedeem(lender), 0, "maxRedeem");
    }

    /// @dev The vault rejects at the ERC-4626 max guard rather than surfacing the controller's pause error,
    ///      because the limit reads zero before the core is ever reached.
    function testRevert_Paused_VaultDepositRejectedAtMaxGuard() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        vm.startPrank(lender);
        m.loanToken.approve(address(m.vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSignature("ERC4626ExceededMaxDeposit(address,uint256,uint256)", lender, 1 ether, 0)
        );
        m.vault.deposit(1 ether, lender);
        vm.stopPrank();
    }

    function testRevert_Paused_VaultRedeemRejectedAtMaxGuard() public {
        Market storage m = _m();
        uint256 shares = _seed(5000);
        m.pause(1 days);

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", lender, shares, 0));
        m.vault.redeem(shares, lender, lender);
    }

    // ── The clock runs, the books do not ──

    /// @dev Pause stops accrual from being *booked*, not time from passing. Stored totals are unchanged
    ///      across the whole pause, then the first action after resume books the entire elapsed interest.
    function test_Paused_InterestIsNotBookedUntilFirstActionAfterResume() public {
        Market storage m = _m();
        _seed(9000);
        m.warpAndAccrue(1 days); // book everything up to the pause so the delta is clean

        uint128 borrowBefore = m.core.market(m.id).totalBorrowAssets;
        uint256 lastUpdateBefore = m.core.market(m.id).lastUpdate;

        m.pause(60 days);
        vm.warp(block.timestamp + 30 days);
        assertTrue(IPausableUntil(address(m.controller)).isPaused(), "setup: pause must outlast the warp");

        assertEq(m.core.market(m.id).totalBorrowAssets, borrowBefore, "nothing booked while paused");
        assertEq(m.core.market(m.id).lastUpdate, lastUpdateBefore, "accrual clock not advanced while paused");

        m.resume();
        m.accrueInterest();

        assertGt(m.core.market(m.id).totalBorrowAssets, borrowBefore, "elapsed interest booked in one step");
        assertEq(m.core.market(m.id).lastUpdate, block.timestamp, "accrual caught up to now");
    }

    /// @dev The cost of pausing: a keeper cannot liquidate while the market is paused, so a crash that
    ///      happens during the pause is only realised afterwards — by then as bad debt.
    function test_Paused_LiquidationBlocked_BadDebtRealisedAtResume() public {
        Market storage m = _m();
        _seed(9900);
        m.pause(7 days);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 4); // deeply underwater

        // Read the collateral into a local first: an external call inside the argument list would itself be
        // "the next call" and would consume the revert expectation.
        uint256 seizeAll = m.core.position(m.id, borrower).collateral;

        vm.startPrank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.liquidate(m.params, borrower, seizeAll, 0, "");
        vm.stopPrank();

        m.resume();
        m.liquidateBadDebt(keeper, borrower, seizeAll, 0);
    }

    // ── Actions that never reach the controller keep working ──

    function test_Paused_SettlementLtvOptInStillWorks() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);
        m.setSettlementLtv(borrower, 0.6e18);
    }

    function test_Paused_VaultShareTransferStillWorks() public {
        Market storage m = _m();
        uint256 shares = _seed(5000);
        m.pause(1 days);

        address recipient = _actor("shareRecipient");
        vm.prank(lender);
        m.vault.transfer(recipient, shares / 2);

        assertEq(m.vault.balanceOf(recipient), shares / 2, "share transfer is not gated by pause");
    }

    function test_Paused_CoreAuthorizationStillWorks() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        address operator = _actor("operator");
        vm.prank(lender);
        m.core.setAuthorization(operator, true);

        assertTrue(m.core.isAuthorized(lender, operator), "authorization is not gated by pause");
    }

    // ── Pause lifecycle ──

    function test_FinitePause_ExpiresWithoutIntervention() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        vm.warp(block.timestamp + 1 days + 1);
        assertFalse(IPausableUntil(address(m.controller)).isPaused(), "finite pause must expire on its own");

        m.accrueInterest(); // a hooked action works again with no resume call
    }

    function test_InfinitePause_NeverExpiresAndNeedsExplicitResume() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(type(uint256).max); // PAUSE_INFINITELY

        vm.warp(block.timestamp + 3650 days);
        assertTrue(IPausableUntil(address(m.controller)).isPaused(), "indefinite pause must not expire");

        m.resume();
        m.accrueInterest();
    }

    /// @dev Extending a pause is resume-then-pause, not a second `pauseFor`: re-pausing while paused reverts,
    ///      so an operator who expects to extend in place gets a revert instead.
    function testRevert_PauseWhileAlreadyPaused_Rejected() public {
        Market storage m = _m();
        _seed(5000);
        m.pause(1 days);

        vm.prank(m.config.admin);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.controller.pauseFor(2 days);
    }

    function testRevert_ResumeWhileNotPaused_Rejected() public {
        Market storage m = _m();
        _seed(5000);
        assertFalse(IPausableUntil(address(m.controller)).isPaused(), "setup: market must be running");

        vm.startPrank(m.config.admin);
        m.controller.grantRole(m.controller.RESUMER_ROLE(), m.config.admin);
        vm.expectRevert(PausableUntil.PausedExpected.selector);
        m.controller.resume();
        vm.stopPrank();
    }

    function testRevert_PauseForZeroDuration_Rejected() public {
        Market storage m = _m();
        _seed(5000);

        vm.startPrank(m.config.admin);
        m.controller.grantRole(m.controller.PAUSER_ROLE(), m.config.admin);
        vm.expectRevert(PausableUntil.ZeroPauseDuration.selector);
        m.controller.pauseFor(0);
        vm.stopPrank();
    }

    // ── I-M003: debt compounds while the pause blocks every cure ──

    /// @dev Pins open finding I-M003: a borrower healthy at the pause start becomes liquidatable from 21 days of
    ///      interest alone, with no way to cure. A fix changes this outcome; update this test with the fix.
    function test_IM003_pause21dAtFullUse_healthyBorrowerLiquidatedAtResume() public {
        Market storage m = _m();
        _seedFullUtilization();
        uint256 price = m.oracle.price();
        assertLt(_ltv(borrower), LLTV, "setup: healthy when the pause starts");

        _bookPauseAtResume(21 days);

        assertEq(m.oracle.price(), price, "no price move");
        assertGt(_ltv(borrower), LLTV, "interest alone crossed LLTV");
        m.liquidate(keeper, borrower, 0, m.core.position(m.id, borrower).borrowShares);
    }

    /// @dev Pins open finding I-M003: a 60-day pause, the CircuitBreaker maximum, turns a healthy borrower into bad
    ///      debt from interest alone. A fix changes this outcome; update this test with the fix.
    function test_IM003_pause60dAtFullUse_badDebtAtResume() public {
        Market storage m = _m();
        _seedFullUtilization();
        uint256 price = m.oracle.price();
        assertLt(_ltv(borrower), LLTV, "setup: healthy when the pause starts");

        _bookPauseAtResume(60 days);

        assertEq(m.oracle.price(), price, "no price move");
        assertGt(_ltv(borrower), WAD, "debt exceeds the collateral value");
        m.liquidateBadDebt(keeper, borrower, m.core.position(m.id, borrower).collateral, 0);
    }

    /// @dev Pins open finding I-M003: the owner's `setFee` accrues through a pause, so it books interest and mints fee
    ///      shares while users stay locked out. A fix changes this outcome; update this test with the fix.
    function test_IM003_ownerSetFeeWhilePaused_accruesAndMintsFeeShares() public {
        Market storage m = _m();
        address feeRecipient = _actor("feeRecipient");
        m.core.setFeeRecipient(feeRecipient);
        m.core.setFee(m.params, 0.1e18);
        _seedFullUtilization();
        m.pause(21 days);
        vm.warp(block.timestamp + 10 days);

        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.accrueInterest(m.params);

        MorphoMarket memory pre = m.core.market(m.id);
        uint256 interest = _pendingInterest();
        uint256 feeAmount = interest.wMulDown(0.1e18);
        uint256 feeShares = feeAmount.toSharesDown(pre.totalSupplyAssets + interest - feeAmount, pre.totalSupplyShares);
        uint256 recipientShares = m.core.position(m.id, feeRecipient).supplyShares;

        m.core.setFee(m.params, 0.2e18);

        MorphoMarket memory post = m.core.market(m.id);
        assertTrue(IPausableUntil(address(m.controller)).isPaused(), "still paused");
        assertEq(post.lastUpdate, block.timestamp, "setFee checkpointed accrual");
        assertEq(post.totalBorrowAssets, pre.totalBorrowAssets + interest, "10 paused days booked");
        assertGt(feeShares, 0, "setup: the interval earns a fee");
        assertEq(
            m.core.position(m.id, feeRecipient).supplyShares, recipientShares + feeShares, "fee shares at the old fee"
        );
        assertEq(post.fee, 0.2e18, "new fee stored");
    }

    /// @dev Pins open finding I-M003: during a pause only the IRM owner's direct `applyIrmConfig` can reprice, since
    ///      the router's switch accrues first. A fix changes this outcome; update this test with the fix.
    function test_IM003_irmRepairWhilePaused_onlyDirectOwnerApplyReprices() public {
        Market storage m = _m();
        _seedFullUtilization();
        MorphoMarket memory atPause = m.core.market(m.id);
        m.pause(21 days);
        uint256 resumeSince = IPausableUntil(address(m.controller)).getResumeSinceTimestamp();
        vm.warp(block.timestamp + 10 days);

        IrmId irmId = IrmId.wrap(Id.unwrap(m.id));
        AdaptiveCurveIrm irm = AdaptiveCurveIrm(address(IrmRouter(m.irm).marketIrm(irmId)));
        IrmMarketParams memory irmParams = _irmParams();

        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        IrmRouter(m.irm).setMarketIrm(irmParams, IrmIIrm(address(irm)));

        address flatConfig = address(new AdaptiveCurveConfig(_flatCurve()));
        irm.applyIrmConfig(irmParams, flatConfig);
        assertEq(address(irm.marketCurveConfig(irmId)), flatConfig, "applied while paused");

        // At full utilization the flat curve charges steepness times its rate at target, over the whole interval
        // since the last accrual, including the ten days before the apply.
        vm.warp(resumeSince);
        uint256 rate = uint256(FLAT_STEEPNESS * FLAT_RATE_AT_TARGET / 1e18);
        uint256 interest =
            uint256(atPause.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(resumeSince - atPause.lastUpdate));
        m.accrueInterest();

        assertEq(m.core.market(m.id).totalBorrowAssets, atPause.totalBorrowAssets + interest, "repriced interval");
        assertLt(_ltv(borrower), LLTV, "the reprice keeps the borrower healthy");
    }

    /// @dev Lender in, the borrower at `BORROWER_LTV`, and a filler at LTV 0.5 borrowing the rest, so utilization is
    ///      exactly 100%.
    function _seedFullUtilization() internal {
        Market storage m = _m();
        address filler = _actor("filler");
        m.vaultDeposit(lender, 1000 ether);
        uint256 borrowerDebt = _collateralValue(100 ether) * BORROWER_LTV / WAD;
        uint256 fillerDebt = m.core.market(m.id).totalSupplyAssets - borrowerDebt;
        uint256 fillerCollateral = fillerDebt * 2 * ORACLE_PRICE_SCALE / oraclePrice;
        _fund(m.collateralToken, filler, fillerCollateral);

        m.supplyCollateral(borrower, 100 ether);
        m.supplyCollateral(filler, fillerCollateral);
        m.activateCollateral();
        m.borrow(borrower, borrowerDebt);
        m.borrow(filler, fillerDebt);

        MorphoMarket memory market = m.core.market(m.id);
        assertEq(market.totalBorrowAssets, market.totalSupplyAssets, "setup: utilization is 100%");
    }

    /// @dev Pauses for `duration`, waits until the pause lapses, then books the whole interval with one accrual.
    ///      Asserts the booked interest against the IRM's rate for the interval, compounded as the core does.
    function _bookPauseAtResume(uint256 duration) internal {
        Market storage m = _m();
        m.pause(duration);
        vm.warp(IPausableUntil(address(m.controller)).getResumeSinceTimestamp());
        assertFalse(IPausableUntil(address(m.controller)).isPaused(), "setup: the pause lapsed");

        uint128 borrowBefore = m.core.market(m.id).totalBorrowAssets;
        uint256 interest = _pendingInterest();
        m.accrueInterest();
        assertEq(m.core.market(m.id).totalBorrowAssets, borrowBefore + interest, "paused interval booked at resume");
    }

    /// @dev Interest the next accrual must book: the IRM's average rate since `lastUpdate`, Taylor-compounded over
    ///      the elapsed time.
    function _pendingInterest() internal view returns (uint256) {
        Market storage m = _m();
        MorphoMarket memory market = m.core.market(m.id);
        uint256 rate = IIrm(m.params.irm).borrowRateView(m.params, market);
        return uint256(market.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(block.timestamp - market.lastUpdate));
    }

    function _ltv(address account) internal view returns (uint256) {
        Market storage m = _m();
        MorphoMarket memory market = m.core.market(m.id);
        uint256 debt = uint256(m.core.position(m.id, account).borrowShares)
            .toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        return debt * WAD / _collateralValue(m.core.position(m.id, account).collateral);
    }

    function _collateralValue(uint256 collateral) internal view returns (uint256) {
        return collateral * _m().oracle.price() / ORACLE_PRICE_SCALE;
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

    /// @dev A valid curve with no adaptation: the rate at target is pinned to `FLAT_RATE_AT_TARGET`.
    function _flatCurve() internal pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: FLAT_STEEPNESS,
            adjustmentSpeed: 0,
            targetUtilization: 0.9e18,
            initialRateAtTarget: FLAT_RATE_AT_TARGET,
            minRateAtTarget: FLAT_RATE_AT_TARGET,
            maxRateAtTarget: FLAT_RATE_AT_TARGET,
            maxBorrowRate: 0
        });
    }
}
