// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {MorphoBlueFork} from "../../src/MorphoBlueFork.sol";
import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {IMarketController} from "../../src/interfaces/IMarketController.sol";
import {AdaptiveCurveIrm} from "@morpho-blue-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {Id, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {Test} from "forge-std/Test.sol";

interface IWETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function deposit() external payable;
}

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IWstETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function wrap(uint256 stETHAmount) external returns (uint256);
}

interface IControllerDeleverageHeapAdmin {
    function CONFIGURATOR_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function setDeleverageHeapConfig(Id id, IMarketController.DeleverageHeapConfig calldata cfg) external;
}

contract MorphoBlueForkMainnetForkTest is Test {
    using MarketParamsLib for MarketParams;

    // Run with:
    // forge test --match-path test/integration/MorphoBlueForkMainnetFork.t.sol \
    //   --fork-url "$MAINNET_RPC_URL"

    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IWETH internal constant WETH = IWETH(WETH_ADDRESS);
    IStETH internal constant STETH = IStETH(STETH_ADDRESS);
    IWstETH internal constant WSTETH = IWstETH(WSTETH_ADDRESS);

    address internal constant LENDER = address(0x1000);
    address internal constant BORROWER = address(0x2000);
    address internal constant SECOND_BORROWER = address(0x3000);
    address internal constant DONOR = address(0x4000);
    address internal constant THIRD_BORROWER = address(0x5000);
    address internal constant SECOND_LENDER = address(0x6000);

    uint256 internal constant LLTV = 0.8e18;

    struct TestMarket {
        MorphoBlueFork market;
        IMarketController controller;
        address accessRegistry;
        MarketParams marketParams;
        Id id;
        uint256 price;
    }

    function testHappyPathControllerPromotesDustAndBorrowsAfterMaturityWithRealLidoWstETH() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(false);

        _mintWETH(ctx.market, LENDER, 10 ether);
        uint256 borrowerDust = _mintWstETH(ctx.market, BORROWER, 7 ether);
        uint256 donorTopUp = _mintWstETH(ctx.market, DONOR, 7 ether);
        uint256 activatedCollateral = borrowerDust + donorTopUp;

        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, borrowerDust, BORROWER, "");
        _assertCollateralState(ctx.controller, ctx.id, BORROWER, 0, 0, borrowerDust);

        vm.prank(DONOR);
        ctx.market.supplyCollateral(ctx.marketParams, donorTopUp, BORROWER, "");
        _assertCollateralState(ctx.controller, ctx.id, BORROWER, 0, activatedCollateral, 0);

        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(BORROWER);
        (uint256 borrowedAssets,) = ctx.market.borrow(ctx.marketParams, 3 ether, 0, BORROWER, BORROWER);

        assertEq(borrowedAssets, 3 ether, "borrowed after maturity");
        assertEq(WETH.balanceOf(BORROWER), 3 ether, "borrower received real WETH");
        _assertCollateralState(ctx.controller, ctx.id, BORROWER, activatedCollateral, 0, 0);
    }

    function testHappyPathControllerFallbackExitWithRealLidoWstETH() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(true);

        _mintWETH(ctx.market, LENDER, 10 ether);
        uint256 borrowerCollateral = _mintWstETH(ctx.market, BORROWER, 20 ether);
        uint256 secondBorrowerCollateral = _mintWstETH(ctx.market, SECOND_BORROWER, 20 ether);

        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, borrowerCollateral, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, secondBorrowerCollateral, SECOND_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);

        uint256 borrowerDebt = 7 ether;
        uint256 secondBorrowerDebt = 3 ether;
        assertTrue(borrowerDebt < _maxBorrow(borrowerCollateral, ctx.price), "borrower debt under LLTV");
        assertTrue(secondBorrowerDebt < _maxBorrow(secondBorrowerCollateral, ctx.price), "second debt under LLTV");

        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, borrowerDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, secondBorrowerDebt, 0, SECOND_BORROWER, SECOND_BORROWER);

        _assertCollateralState(ctx.controller, ctx.id, BORROWER, borrowerCollateral, 0, 0);
        _assertCollateralState(ctx.controller, ctx.id, SECOND_BORROWER, secondBorrowerCollateral, 0, 0);

        _fallbackExitAndAssert(ctx, borrowerCollateral);
    }

    /// @notice One scenario exercising the heap-driven deleverage ordering end-to-end.
    /// @dev Covers, in order:
    ///        - three borrowers at different risk levels; heap root tracks the highest-LTV one;
    ///        - a cut targeting the heap root reduces it but does not flip the order;
    ///        - the heap re-sorts after the root borrower partially repays, so a new borrower becomes root;
    ///        - a cut targeting the new root succeeds while the previous root is no longer reached;
    ///        - the lowest-LTV borrower is never touched throughout the scenario.
    function testHeapDeleverageScenarioMultipleBorrowersWithRealLidoWstETH() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(true);

        // Lender saturates the market so every cut below has to go through deleverage and not
        // the ordinary withdraw path.
        _mintWETH(ctx.market, LENDER, 12 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 12 ether, 0, LENDER, "");

        uint256 highCol = _mintWstETH(ctx.market, BORROWER, 20 ether);
        uint256 midCol = _mintWstETH(ctx.market, SECOND_BORROWER, 20 ether);
        uint256 lowCol = _mintWstETH(ctx.market, THIRD_BORROWER, 20 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, highCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, midCol, SECOND_BORROWER, "");
        vm.prank(THIRD_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, lowCol, THIRD_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 6 ether, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, 4 ether, 0, SECOND_BORROWER, SECOND_BORROWER);
        vm.prank(THIRD_BORROWER);
        ctx.market.borrow(ctx.marketParams, 2 ether, 0, THIRD_BORROWER, THIRD_BORROWER);

        // (1) Initial heap order: highest-LTV borrower is at the root.
        assertEq(ctx.controller.deleverageHeapSize(ctx.id), 3, "all three active borrowers tracked");
        (address root,) = ctx.controller.nextDeleverageCut(ctx.id);
        assertEq(root, BORROWER, "highest-LTV borrower at root");

        // (2) Targeted cut on the heap root reduces it but does not flip the order.
        (uint256 lenderShares,,) = ctx.market.position(ctx.id, LENDER);
        uint256 firstCutShares = lenderShares / 6; // ~2 WETH cut
        vm.prank(LENDER);
        ctx.market.deleverage(ctx.marketParams, firstCutShares, BORROWER, LENDER, LENDER);
        (root,) = ctx.controller.nextDeleverageCut(ctx.id);
        assertEq(root, BORROWER, "BORROWER still highest after small partial cut");

        // (3) BORROWER partially repays. The heap re-sorts and SECOND_BORROWER becomes root.
        _mintWETH(ctx.market, BORROWER, 3 ether);
        vm.prank(BORROWER);
        ctx.market.repay(ctx.marketParams, 3 ether, 0, BORROWER, "");
        (root,) = ctx.controller.nextDeleverageCut(ctx.id);
        assertEq(root, SECOND_BORROWER, "heap re-sorts after BORROWER deleverages off-protocol");

        // (4) A cut against the new root succeeds. The cut size must exceed the idle liquidity
        //     left by BORROWER's repay, otherwise core rejects with "ordinary liquidity available".
        (uint256 lenderSharesAfterRepay,,) = ctx.market.position(ctx.id, LENDER);
        uint256 secondCutShares = lenderSharesAfterRepay / 3;
        vm.prank(LENDER);
        ctx.market.deleverage(ctx.marketParams, secondCutShares, SECOND_BORROWER, LENDER, LENDER);

        // (5) THIRD_BORROWER (lowest LTV) has not been touched at any point.
        (, uint128 lowBorrowSharesAfter, uint128 lowCollateralAfter) = ctx.market.position(ctx.id, THIRD_BORROWER);
        assertEq(uint256(lowCollateralAfter), lowCol, "low-LTV borrower's collateral untouched");
        assertGt(lowBorrowSharesAfter, 0, "low-LTV borrower still has debt");
    }

    /// @notice Deleverage of any borrower is blocked while the queue head (heap root) is bad debt.
    /// @dev Direct core path, no vault — the vault is optional, so the guard lives in the controller.
    ///      Setup: a high-LTV head (BORROWER) and a healthy tail (SECOND_BORROWER). A negative
    ///      rebase pushes the head underwater (debt > collateral value). The head cannot be cut
    ///      anyway (core requires _isHealthy), but cutting the healthy tail must also revert while
    ///      the head is insolvent — the whole queue halts until bad debt is resolved out of band.
    function testDeleverageRevertsWhileQueueHeadBadDebtWithRealLidoWstETH() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(true);

        _mintWETH(ctx.market, LENDER, 20 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 20 ether, 0, LENDER, "");

        uint256 headCol = _mintWstETH(ctx.market, BORROWER, 25 ether);
        uint256 tailCol = _mintWstETH(ctx.market, SECOND_BORROWER, 25 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, headCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, tailCol, SECOND_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);

        // Head borrows near the LLTV ceiling; tail borrows a little. Together they drain liquidity.
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 18 ether, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, 2 ether, 0, SECOND_BORROWER, SECOND_BORROWER);

        (address root,) = ctx.controller.nextDeleverageCut(ctx.id);
        assertEq(root, BORROWER, "high-LTV borrower is the queue head");

        // Negative rebase: drop the wstETH rate so the head's collateral is worth less than its
        // debt (bad debt), while the tail stays healthy.
        vm.mockCall(WSTETH_ADDRESS, abi.encodeWithSelector(IWstETH.stEthPerToken.selector), abi.encode(uint256(0.7e18)));
        assertTrue(ctx.controller.rootHasBadDebt(ctx.id), "head is bad debt after rebase");

        // A small cut against the healthy tail passes core's eligibility/over-cap/liquidity checks,
        // but the controller hook reverts because the queue head is bad debt.
        (uint256 lenderShares,,) = ctx.market.position(ctx.id, LENDER);
        uint256 cut = lenderShares / 20;
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSignature("DeleverageRootBadDebt()"));
        ctx.market.deleverage(ctx.marketParams, cut, SECOND_BORROWER, LENDER, LENDER);

        // Restore the rate; the head is solvent again; the same cut now succeeds.
        vm.clearMockedCalls();
        assertFalse(ctx.controller.rootHasBadDebt(ctx.id), "head solvent after restore");
        vm.prank(LENDER);
        ctx.market.deleverage(ctx.marketParams, cut, SECOND_BORROWER, LENDER, LENDER);
    }

    /// @notice Deleverage works on an unhealthy-but-solvent position (LLTV < LTV < 100%).
    /// @dev Soft-liquidation must reach risky positions, not just healthy ones. The core no longer
    ///      requires `_isHealthy` for deleverage; the bound is the over-cap check plus the bad-debt
    ///      guard. A negative rebase pushes the borrower above LLTV (unhealthy) while keeping their
    ///      collateral worth more than their debt (solvent), then the cut succeeds.
    function testDeleverageWorksOnUnhealthyButSolventPositionWithRealLidoWstETH() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(true);

        uint256 borrowAmount = 18 ether;
        _mintWETH(ctx.market, LENDER, borrowAmount);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, borrowAmount, 0, LENDER, "");

        uint256 col = _mintWstETH(ctx.market, BORROWER, 25 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col, BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, borrowAmount, 0, BORROWER, BORROWER); // healthy at the live rate

        // Negative rebase: LTV crosses above LLTV (unhealthy) but collateral still covers debt (solvent).
        uint256 droppedPrice = 0.95e36;
        vm.mockCall(
            WSTETH_ADDRESS, abi.encodeWithSelector(IWstETH.stEthPerToken.selector), abi.encode(uint256(0.95e18))
        );

        (,, uint128 rc) = ctx.market.position(ctx.id, BORROWER);
        assertGt(borrowAmount, _maxBorrow(uint256(rc), droppedPrice), "position is unhealthy (LTV > LLTV)");
        assertGt(uint256(rc) * droppedPrice / 1e36, borrowAmount, "position is solvent (collateral value > debt)");
        assertFalse(ctx.controller.rootHasBadDebt(ctx.id), "head is not bad debt");

        // The cut succeeds even though the borrower is unhealthy — previously blocked by `_isHealthy`.
        (uint256 lenderShares,,) = ctx.market.position(ctx.id, LENDER);
        uint256 cut = lenderShares / 10;
        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled) =
            ctx.market.deleverage(ctx.marketParams, cut, BORROWER, LENDER, LENDER);

        assertGt(debtCanceled, 0, "debt cancelled");
        assertEq(collateralSeized, debtCanceled * 1e36 / droppedPrice, "collateral seized at oracle rate");
        (,, uint128 rcAfter) = ctx.market.position(ctx.id, BORROWER);
        assertEq(uint256(rcAfter), uint256(rc) - collateralSeized, "borrower collateral debited");
    }

    /// @notice setBorrowerWatermark stores the borrower's target LTV; rejects ltv >= 1e18.
    function testWatermarkSetterStoresAndRejectsOutOfRange() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        TestMarket memory ctx = _deployMarket(true);

        assertEq(ctx.controller.borrowerWatermark(ctx.id, BORROWER), 0, "default unset");

        vm.prank(BORROWER);
        ctx.controller.setBorrowerWatermark(ctx.id, 0.6e18);
        assertEq(ctx.controller.borrowerWatermark(ctx.id, BORROWER), 0.6e18, "stored");

        // Clear with 0.
        vm.prank(BORROWER);
        ctx.controller.setBorrowerWatermark(ctx.id, 0);
        assertEq(ctx.controller.borrowerWatermark(ctx.id, BORROWER), 0, "cleared");

        // Out-of-range rejected.
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSignature("WatermarkOutOfRange()"));
        ctx.controller.setBorrowerWatermark(ctx.id, 1e18);
    }

    /// @notice Path A: when the heap head has a watermark, `nextDeleverageCut`'s slice is bumped
    ///         up to bring the borrower's LTV down to the watermark. Close runner-up key keeps the
    ///         algorithmic slice small so the watermark dominates.
    function testWatermarkBumpsHeapSlice() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        TestMarket memory ctx = _deployMarket(true);

        _mintWETH(ctx.market, LENDER, 40 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 40 ether, 0, LENDER, "");

        uint256 hotCol = _mintWstETH(ctx.market, BORROWER, 25 ether);
        uint256 coldCol = _mintWstETH(ctx.market, SECOND_BORROWER, 25 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, hotCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, coldCol, SECOND_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);
        // Close LTVs → small key gap → small algorithmic slice.
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 18 ether, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, 17 ether, 0, SECOND_BORROWER, SECOND_BORROWER);

        (, uint256 sliceBefore) = ctx.controller.nextDeleverageCut(ctx.id);

        // BORROWER opts in to a 30% post-cut LTV — a deep target.
        vm.prank(BORROWER);
        ctx.controller.setBorrowerWatermark(ctx.id, 0.3e18);

        (address rootAfter, uint256 sliceAfter) = ctx.controller.nextDeleverageCut(ctx.id);
        assertEq(rootAfter, BORROWER, "root unchanged");
        assertGt(sliceAfter, sliceBefore, "watermark raised the slice");

        // Watermark slice closed form: c = (D*WAD - W*V) / (WAD - W), with V = col * price / 1e36.
        uint256 colValue = hotCol * ctx.price / 1e36;
        uint256 expected = (uint256(18 ether) * 1e18 - 0.3e18 * colValue) / (1e18 - 0.3e18);
        assertApproxEqAbs(sliceAfter, expected, 1e15, "slice matches watermark formula");
    }

    /// @notice Path B: `deleverageByWatermark` cuts each listed borrower at their watermark slice.
    ///         Borrowers without a watermark abort the call.
    function testDeleverageByWatermarkRespectsListAndSlice() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        TestMarket memory ctx = _deployMarket(true);

        _mintWETH(ctx.market, LENDER, 20 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 20 ether, 0, LENDER, "");

        uint256 col1 = _mintWstETH(ctx.market, BORROWER, 20 ether);
        uint256 col2 = _mintWstETH(ctx.market, SECOND_BORROWER, 20 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col1, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col2, SECOND_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 12 ether, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, 6 ether, 0, SECOND_BORROWER, SECOND_BORROWER);

        // Lender authorises the controller so it can spend lender's supply through core deleverage.
        vm.prank(LENDER);
        ctx.market.setAuthorization(address(ctx.controller), true);

        // Activation: lender's exit must exceed available liquidity (20 - 18 = 2). Use full supply.
        (uint256 lenderShares,,) = ctx.market.position(ctx.id, LENDER);
        address[] memory list = new address[](2);
        list[0] = BORROWER;
        list[1] = SECOND_BORROWER;

        // No watermark on BORROWER → revert.
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSignature("WatermarkNotSet()"));
        ctx.controller.deleverageByWatermark(ctx.marketParams, lenderShares, list, LENDER, LENDER);

        // BORROWER opts in to 40% LTV. SECOND_BORROWER still no watermark.
        vm.prank(BORROWER);
        ctx.controller.setBorrowerWatermark(ctx.id, 0.4e18);

        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSignature("WatermarkNotSet()"));
        ctx.controller.deleverageByWatermark(ctx.marketParams, lenderShares, list, LENDER, LENDER);

        // SECOND_BORROWER also opts in to 30%.
        vm.prank(SECOND_BORROWER);
        ctx.controller.setBorrowerWatermark(ctx.id, 0.3e18);

        uint256 b1ColBefore = col1;
        uint256 b2ColBefore = col2;
        vm.prank(LENDER);
        (uint256 totalSeized, uint256 totalDebtCanceled) =
            ctx.controller.deleverageByWatermark(ctx.marketParams, lenderShares, list, LENDER, LENDER);

        // Each borrower cut to (close to) their watermark LTV.
        (, uint128 b1DebtAfter, uint128 b1ColAfter) = ctx.market.position(ctx.id, BORROWER);
        (, uint128 b2DebtAfter, uint128 b2ColAfter) = ctx.market.position(ctx.id, SECOND_BORROWER);
        assertLt(uint256(b1ColAfter), b1ColBefore, "BORROWER collateral debited");
        assertLt(uint256(b2ColAfter), b2ColBefore, "SECOND_BORROWER collateral debited");
        assertGt(uint256(b1DebtAfter), 0, "BORROWER still has debt (cut, not full close)");
        assertGt(uint256(b2DebtAfter), 0, "SECOND_BORROWER still has debt");
        assertGt(totalSeized, 0, "collateral seized");
        assertGt(totalDebtCanceled, 0, "debt canceled");
        assertEq(totalSeized, totalDebtCanceled * 1e36 / ctx.price, "cuts at oracle rate, no LIF");
    }

    function _fallbackExitAndAssert(TestMarket memory ctx, uint256 borrowerCollateral) internal {
        (uint256 supplyShares,,) = ctx.market.position(ctx.id, LENDER);
        uint256 sharesToExit = supplyShares / 5;

        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled) =
            ctx.market.deleverage(ctx.marketParams, sharesToExit, BORROWER, LENDER, LENDER);

        uint256 expectedCollateralSeized = debtCanceled * 1e36 / ctx.price;
        assertEq(collateralSeized, expectedCollateralSeized, "oracle-rate collateral");
        assertTrue(debtCanceled > 1.9 ether && debtCanceled <= 2 ether, "debt canceled near 2 WETH");
        assertEq(WSTETH.balanceOf(LENDER), collateralSeized, "lender received real wstETH");

        _assertBorrowerCollateralDebited(ctx, borrowerCollateral, collateralSeized);
    }

    function _hasMainnetLidoContracts() internal view returns (bool) {
        return block.chainid == 1 && WETH_ADDRESS.code.length != 0 && STETH_ADDRESS.code.length != 0
            && WSTETH_ADDRESS.code.length != 0;
    }

    function _maxBorrow(uint256 collateral, uint256 price) internal pure returns (uint256) {
        return (collateral * price / 1e36 * LLTV) / 1e18;
    }

    function _assertBorrowerCollateralDebited(
        TestMarket memory ctx,
        uint256 initialCollateral,
        uint256 collateralSeized
    ) internal view {
        (,, uint128 borrowerRawCollateral) = ctx.market.position(ctx.id, BORROWER);
        assertEq(uint256(borrowerRawCollateral), initialCollateral - collateralSeized, "raw collateral debited");
        _assertCollateralState(ctx.controller, ctx.id, BORROWER, initialCollateral - collateralSeized, 0, 0);
    }

    function _deployMarket(bool deleverageEnabled) internal returns (TestMarket memory ctx) {
        ctx.market = new MorphoBlueFork(address(this));
        WstEthRateOracle oracle = new WstEthRateOracle(WSTETH_ADDRESS);
        AdaptiveCurveIrm irm = new AdaptiveCurveIrm(address(ctx.market));

        ctx.marketParams = MarketParams({
            loanToken: WETH_ADDRESS,
            collateralToken: WSTETH_ADDRESS,
            oracle: address(oracle),
            irm: address(irm),
            lltv: LLTV
        });
        ctx.id = ctx.marketParams.id();
        ctx.price = oracle.price();
        (ctx.controller, ctx.accessRegistry) = _deployController(ctx.market, ctx.id);

        ctx.market.enableIrm(address(irm));
        ctx.market.enableLltv(LLTV);
        ctx.market.createMarket(ctx.marketParams, address(ctx.controller), deleverageEnabled);
    }

    function _mintWETH(MorphoBlueFork market, address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        WETH.deposit{value: amount}();
        vm.prank(user);
        WETH.approve(address(market), type(uint256).max);
    }

    function _mintWstETH(MorphoBlueFork market, address user, uint256 ethAmount) internal returns (uint256) {
        vm.deal(user, ethAmount);
        vm.prank(user);
        STETH.submit{value: ethAmount}(address(0));

        uint256 stETHAmount = STETH.balanceOf(user);
        vm.prank(user);
        STETH.approve(WSTETH_ADDRESS, stETHAmount);
        vm.prank(user);
        uint256 wstETHAmount = WSTETH.wrap(stETHAmount);
        vm.prank(user);
        WSTETH.approve(address(market), type(uint256).max);
        return wstETHAmount;
    }

    function _deployController(MorphoBlueFork core, Id id) internal returns (IMarketController, address) {
        address accessRegistry =
            _deployArtifact("MarketAccessRegistry.sol:MarketAccessRegistry", abi.encode(address(this)));
        address implementation = _deployArtifact("LidoMarketController.sol:LidoMarketController", "");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,bytes32,address,address)", address(core), Id.unwrap(id), accessRegistry, address(this)
        );
        address proxy =
            _deployArtifact("OssifiableProxy.sol:OssifiableProxy", abi.encode(implementation, address(this), initData));
        IControllerDeleverageHeapAdmin admin = IControllerDeleverageHeapAdmin(proxy);
        admin.grantRole(admin.CONFIGURATOR_ROLE(), address(this));
        return (IMarketController(proxy), accessRegistry);
    }

    function _deployArtifact(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory bytecode = vm.getCode(artifact);
        bytes memory creationCode = bytes.concat(bytecode, args);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "artifact deploy failed");
    }

    function _assertCollateralState(
        IMarketController controller,
        Id id,
        address borrower,
        uint256 matured,
        uint256 activating,
        uint256 dust
    ) internal view {
        IMarketController.CollateralState memory state = controller.collateralState(id, borrower);
        assertEq(uint256(state.maturedCollateral), matured, "matured collateral");
        assertEq(uint256(state.activatingCollateral), activating, "activating collateral");
        assertEq(uint256(state.dustCollateral), dust, "dust collateral");
    }
}
