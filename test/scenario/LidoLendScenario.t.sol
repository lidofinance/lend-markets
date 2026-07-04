// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {Id, MarketParams, Position, Market} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Test} from "forge-std/Test.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {BlockInfoWithHash} from "../../src/types/GuardianSignalsTypes.sol";

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
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function wrap(uint256 stETHAmount) external returns (uint256);
}

/// @dev Minimal guardian surface used to flag (and thereby ban, at quorum) an account in tests.
interface IRegistryLike {
    function flag(Id market, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external;
}

/// @dev Runs a supplyCollateral -> withdrawCollateral round-trip in ONE call frame (one tx), so the
///      controller's same-tx flash-undo fires. Holds the collateral and is its own onBehalf/receiver.
contract FlashRoundTrip {
    function run(ILidoLend market, MarketParams calldata params, uint256 amount) external {
        market.supplyCollateral(params, amount, address(this), "");
        market.withdrawCollateral(params, amount, address(this), address(this));
    }
}

/// @notice End-to-end scenario over a freshly deployed ILidoLend + LidoLendMarketController stack on a
///         mainnet fork (real Lido stETH/wstETH). Drives supply/borrow/maturation and the settle
///         queue (heap ordering, settlement LTV, bad-debt guard) through the controller's hooks.
contract LidoLendScenarioTest is Test, LidoLendDeployer {
    using MarketParamsLib for MarketParams;

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

    uint256 internal constant LLTV = 0.8e18;

    struct TestMarket {
        ILidoLend market;
        ILidoLendMarketController controller;
        address guardianSignals;
        MarketParams marketParams;
        Id id;
        uint256 price;
    }

    function test_supplyCollateral_promotesDustAndBorrowsAfterMaturity() public {
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
        _assertCollateralState(ctx.controller, BORROWER, 0, 0, borrowerDust);

        vm.prank(DONOR);
        ctx.market.supplyCollateral(ctx.marketParams, donorTopUp, BORROWER, "");
        _assertCollateralState(ctx.controller, BORROWER, 0, activatedCollateral, 0);

        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(BORROWER);
        (uint256 borrowedAssets,) = ctx.market.borrow(ctx.marketParams, 3 ether, 0, BORROWER, BORROWER);

        assertEq(borrowedAssets, 3 ether, "borrowed after maturity");
        assertEq(WETH.balanceOf(BORROWER), 3 ether, "borrower received real WETH");
        _assertCollateralState(ctx.controller, BORROWER, activatedCollateral, 0, 0);
    }

    /// @notice Instant activation (whitelist): a trusted borrower's collateral is active on deposit, so it
    ///         borrows with no maturation wait. Revoking restores the timer for fresh deposits.
    function test_instantActivation_skipsMaturationDelay() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(false);
        ctx.controller.grantInstantActivation(BORROWER);
        assertTrue(ctx.controller.hasInstantActivation(BORROWER), "borrower whitelisted");

        _mintWETH(ctx.market, LENDER, 10 ether);
        uint256 col = _mintWstETH(ctx.market, BORROWER, 18 ether);

        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col, BORROWER, "");

        // No warp: the deposit is active immediately, so the borrow goes through.
        _assertCollateralState(ctx.controller, BORROWER, col, 0, 0);
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 3 ether, 0, BORROWER, BORROWER);
        assertEq(WETH.balanceOf(BORROWER), 3 ether, "borrowed with no maturation wait");

        // Revoke restores the timer: a fresh deposit enters activation instead of going straight to active.
        ctx.controller.revokeInstantActivation(BORROWER);
        uint256 more = _mintWstETH(ctx.market, BORROWER, 15 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, more, BORROWER, "");
        _assertCollateralState(ctx.controller, BORROWER, col, more, 0);
    }

    /// @notice Open-debt collateral floor: while a borrower owes debt, a withdrawal may not draw active
    ///         collateral below the activation threshold (`minActivationAmount`) — sub-threshold active
    ///         collateral has zero borrow capacity, so the open debt fails the health gate. Repaying to zero
    ///         lifts the constraint.
    function test_withdraw_collateralFloorWithOpenDebt() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(false); // minActivationAmount = 10 ether

        _mintWETH(ctx.market, LENDER, 10 ether);
        uint256 col = _mintWstETH(ctx.market, BORROWER, 18 ether); // ~15 wstETH, comfortably above the threshold
        assertGt(col, 12 ether, "collateral above the threshold for the test");

        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col, BORROWER, "");
        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 2 ether, 0, BORROWER, BORROWER);

        // Down to just above the 10-wstETH threshold is allowed (health is loose, so the threshold is what binds).
        vm.prank(BORROWER);
        ctx.market.withdrawCollateral(ctx.marketParams, col - 11 ether, BORROWER, BORROWER);

        // The next 2 wstETH would drop active collateral to 9 < 10 with open debt: zero capacity, reverts.
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        ctx.market.withdrawCollateral(ctx.marketParams, 2 ether, BORROWER, BORROWER);

        // Repay the debt to zero, then the floor no longer applies and the rest comes out.
        _mintWETH(ctx.market, BORROWER, 3 ether);
        uint128 borrowShares = ctx.market.position(ctx.id, BORROWER).borrowShares;
        vm.prank(BORROWER);
        ctx.market.repay(ctx.marketParams, 0, borrowShares, BORROWER, "");
        vm.prank(BORROWER);
        ctx.market.withdrawCollateral(ctx.marketParams, 11 ether, BORROWER, BORROWER);
    }

    /// @notice Collateral floor on borrow: a position whose active collateral is below the activation threshold
    ///         cannot open debt — its borrow capacity is zero. Symmetric to the withdraw case, but binds before
    ///         any debt exists.
    function test_borrow_belowPositionFloorReverts() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(false); // minActivationAmount = 10 ether

        _mintWETH(ctx.market, LENDER, 10 ether);
        uint256 col = _mintWstETH(ctx.market, BORROWER, 18 ether); // ~15 wstETH, above the threshold
        assertGt(col, 12 ether, "collateral above the threshold for the test");

        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col, BORROWER, "");
        vm.warp(block.timestamp + 2 hours + 1);

        // No debt yet, so the withdraw health gate does not bind: draw active collateral below the threshold.
        vm.prank(BORROWER);
        ctx.market.withdrawCollateral(ctx.marketParams, col - 5 ether, BORROWER, BORROWER);
        _assertCollateralState(ctx.controller, BORROWER, 5 ether, 0, 0); // active collateral = 5 < 10

        // Borrowing against sub-threshold active collateral is blocked (zero capacity), even for a tiny amount.
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        ctx.market.borrow(ctx.marketParams, 1, 0, BORROWER, BORROWER);
    }

    function test_settle_happyPath() public {
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

        _assertCollateralState(ctx.controller, BORROWER, borrowerCollateral, 0, 0);
        _assertCollateralState(ctx.controller, SECOND_BORROWER, secondBorrowerCollateral, 0, 0);

        _settleAndAssert(ctx, borrowerCollateral);
    }

    /// @notice One scenario exercising the heap-driven settle ordering end-to-end.
    /// @dev Covers, in order:
    ///        - three borrowers at different risk levels; queue root tracks the highest-LTV one;
    ///        - a cut targeting the root reduces it but does not flip the order;
    ///        - the root opts another borrower in via a settlement LTV, so a non-root cut succeeds;
    ///        - the lowest-LTV borrower is never touched throughout the scenario.
    function test_settle_heapPicksTopBorrower() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");

        TestMarket memory ctx = _deployMarket(true);

        // Lender saturates the market so every cut below has to go through settle and not
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

        // (1) Initial queue order: highest-LTV borrower is at the root.
        assertEq(ctx.controller.settlementBorrowersCount(), 3, "all three active borrowers tracked");
        (address root,,,) = ctx.controller.nextSettlementBorrower();
        assertEq(root, BORROWER, "highest-LTV borrower at root");

        // (2) A partial cut on the root, half the allowed slice. The full slice is sized to push the
        //     root's key just below the runner-up, so cutting half reduces the key without flipping.
        uint256 firstCutShares = _sliceShares(ctx) / 2;
        vm.prank(LENDER);
        ctx.market.settle(ctx.marketParams, 0, firstCutShares, LENDER, BORROWER, LENDER);
        (root,,,) = ctx.controller.nextSettlementBorrower();
        assertEq(root, BORROWER, "BORROWER still highest after first partial cut");

        // (3) Targeting the second borrower while it isn't the queue root is rejected by the controller hook:
        //     a non-root borrower without a personal settlement LTV has a zero slice, so any cut exceeds it.
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSignature("SettlementExceedsAllowed()"));
        ctx.market.settle(ctx.marketParams, 0, firstCutShares, LENDER, SECOND_BORROWER, LENDER);

        // (4) SECOND_BORROWER opts in to a 5% post-cut LTV — they are now eligible regardless of
        //     queue position. The same cut now succeeds against them.
        vm.prank(SECOND_BORROWER);
        ctx.controller.setSettlementLtv(0.05e18);
        vm.prank(LENDER);
        ctx.market.settle(ctx.marketParams, 0, firstCutShares, LENDER, SECOND_BORROWER, LENDER);

        // (5) THIRD_BORROWER (lowest LTV, no settlement LTV) is never touched throughout the scenario.
        Position memory _pLow = ctx.market.position(ctx.id, THIRD_BORROWER);
        (uint128 lowBorrowSharesAfter, uint128 lowCollateralAfter) = (_pLow.borrowShares, _pLow.collateral);
        assertEq(uint256(lowCollateralAfter), lowCol, "low-LTV borrower's collateral untouched");
        assertGt(lowBorrowSharesAfter, 0, "low-LTV borrower still has debt");
    }

    /// @notice Settle of any borrower is blocked while the queue root is bad debt.
    /// @dev Setup: a high-LTV root (BORROWER) and a healthy tail (SECOND_BORROWER). A negative rebase
    ///      pushes the root underwater (debt > collateral value). Cutting the healthy tail must also
    ///      revert while the root is insolvent — the whole queue halts until bad debt is resolved.
    function testRevert_settle_whenHeapRootBadDebt() public {
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

        (address root,,,) = ctx.controller.nextSettlementBorrower();
        assertEq(root, BORROWER, "high-LTV borrower is the queue head");

        // Cut sized to the allowed slice at the real rate (reused after the rebase is cleared).
        uint256 cut = _sliceShares(ctx) / 2;

        // Negative rebase: drop the wstETH rate so the head's collateral is worth less than its
        // debt (bad debt), while the tail stays healthy.
        vm.mockCall(
            WSTETH_ADDRESS,
            abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector, uint256(1e36)),
            abi.encode(uint256(0.7e36))
        );
        assertTrue(ctx.controller.hasBadDebt(), "head is bad debt after rebase");

        // Even targeting the head itself is blocked while head is bad debt: the controller's bad-debt
        // guard fires on every settle path.
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSignature("SettlementBadDebt()"));
        ctx.market.settle(ctx.marketParams, 0, cut, LENDER, BORROWER, LENDER);

        // Restore the rate; the head is solvent again; the same cut against the head now succeeds.
        vm.clearMockedCalls();
        assertFalse(ctx.controller.hasBadDebt(), "head solvent after restore");
        vm.prank(LENDER);
        ctx.market.settle(ctx.marketParams, 0, cut, LENDER, BORROWER, LENDER);
    }

    /// @notice Settle works on an unhealthy-but-solvent position (LLTV < LTV < 100%).
    /// @dev Soft-liquidation must reach risky positions, not just healthy ones. The bound is the
    ///      over-cap check plus the bad-debt guard. A negative rebase pushes the borrower above LLTV
    ///      (unhealthy) while keeping their collateral worth more than their debt (solvent).
    function test_settle_worksOnUnhealthyButSolventPosition() public {
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
            WSTETH_ADDRESS,
            abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector, uint256(1e36)),
            abi.encode(droppedPrice)
        );

        uint128 rc = ctx.market.position(ctx.id, BORROWER).collateral;
        assertGt(borrowAmount, _maxBorrow(uint256(rc), droppedPrice), "position is unhealthy (LTV > LLTV)");
        assertGt(uint256(rc) * droppedPrice / 1e36, borrowAmount, "position is solvent (collateral value > debt)");
        assertFalse(ctx.controller.hasBadDebt(), "head is not bad debt");

        // The cut succeeds even though the borrower is unhealthy.
        uint256 lenderShares = ctx.market.position(ctx.id, LENDER).supplyShares;
        uint256 cut = lenderShares / 10;
        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            ctx.market.settle(ctx.marketParams, 0, cut, LENDER, BORROWER, LENDER);

        assertGt(debtCanceled, 0, "debt cancelled");
        assertEq(collateralSeized, debtCanceled * 1e36 / droppedPrice, "collateral seized at oracle rate");
        uint128 rcAfter = ctx.market.position(ctx.id, BORROWER).collateral;
        assertEq(uint256(rcAfter), uint256(rc) - collateralSeized, "borrower collateral debited");
    }

    /// @notice setSettlementLtv stores the borrower's target LTV; rejects ltv >= 1e18.
    function test_setSettlementLtv_storesAndRejectsOutOfRange() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        TestMarket memory ctx = _deployMarket(true);

        (uint256 wm0,) = ctx.controller.settlementLtv(BORROWER);
        assertEq(wm0, 0, "default unset");

        vm.prank(BORROWER);
        ctx.controller.setSettlementLtv(0.6e18);
        (uint256 wm1,) = ctx.controller.settlementLtv(BORROWER);
        assertEq(wm1, 0.6e18, "stored");

        // Clear with 0.
        vm.prank(BORROWER);
        ctx.controller.setSettlementLtv(0);
        (uint256 wm2,) = ctx.controller.settlementLtv(BORROWER);
        assertEq(wm2, 0, "cleared");

        // Out-of-range rejected.
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSignature("SettlementLtvOutOfRange()"));
        ctx.controller.setSettlementLtv(1e18);
    }

    /// @notice When the queue root has a settlement LTV, the root's allowed slice is bumped up to bring
    ///         the borrower's LTV down to it. Close runner-up key keeps the algorithmic
    ///         slice small so the settlement-LTV slice dominates.
    function test_settlementLtv_bumpsHeapSlice() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        TestMarket memory ctx = _deployMarket(true);

        _mintWETH(ctx.market, LENDER, 40 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 40 ether, 0, LENDER, "");

        // Collateral sized so the post-cut remainder stays above the activation minimum, keeping the
        // settlement-LTV slice off the dust-extension clamp (which would promote it to the full debt).
        uint256 hotCol = _mintWstETH(ctx.market, BORROWER, 30 ether);
        uint256 coldCol = _mintWstETH(ctx.market, SECOND_BORROWER, 30 ether);
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

        (address rootBefore,,,) = ctx.controller.nextSettlementBorrower();
        uint256 sliceBefore = ctx.controller.positionOf(rootBefore).slice;

        // BORROWER opts in to a 30% post-cut LTV — a deep target.
        vm.prank(BORROWER);
        ctx.controller.setSettlementLtv(0.3e18);

        (address rootAfter,,,) = ctx.controller.nextSettlementBorrower();
        uint256 sliceAfter = ctx.controller.positionOf(rootAfter).slice;
        assertEq(rootAfter, BORROWER, "root unchanged");
        assertGt(sliceAfter, sliceBefore, "settlement LTV raised the slice");

        // Settlement-LTV slice closed form: c = (D*WAD - W*V) / (WAD - W), with V = col * price / 1e36.
        uint256 colValue = hotCol * ctx.price / 1e36;
        uint256 expected = (uint256(18 ether) * 1e18 - 0.3e18 * colValue) / (1e18 - 0.3e18);
        assertApproxEqAbs(sliceAfter, expected, 1e15, "slice matches settlement-LTV formula");
    }

    /// @notice Direct EOA-lender can settle a non-root borrower iff that borrower has a personal
    ///         settlement LTV set. Without one its policy slice is zero, so the controller hook reverts
    ///         `SettlementExceedsAllowed` on any cut.
    function test_settle_eligibleViaPersonalSettlementLtv() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        TestMarket memory ctx = _deployMarket(true);

        _mintWETH(ctx.market, LENDER, 10 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");

        // Two borrowers, BORROWER is the queue root (higher LTV). SECOND_BORROWER is tail. Total
        // borrow drains the supply so the lender's exit must trigger settle.
        uint256 col1 = _mintWstETH(ctx.market, BORROWER, 20 ether);
        uint256 col2 = _mintWstETH(ctx.market, SECOND_BORROWER, 20 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col1, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col2, SECOND_BORROWER, "");

        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 7 ether, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, 3 ether, 0, SECOND_BORROWER, SECOND_BORROWER);

        (address root,,,) = ctx.controller.nextSettlementBorrower();
        assertEq(root, BORROWER, "BORROWER is queue root");

        uint256 lenderShares = ctx.market.position(ctx.id, LENDER).supplyShares;
        uint256 cut = lenderShares / 5;

        // Targeting tail SECOND_BORROWER without a settlement LTV → zero slice → hook revert.
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSignature("SettlementExceedsAllowed()"));
        ctx.market.settle(ctx.marketParams, 0, cut, LENDER, SECOND_BORROWER, LENDER);

        // SECOND_BORROWER opts in to 5% post-cut LTV — slice is large enough for the cut.
        vm.prank(SECOND_BORROWER);
        ctx.controller.setSettlementLtv(0.05e18);

        uint128 colBefore = ctx.market.position(ctx.id, SECOND_BORROWER).collateral;
        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            ctx.market.settle(ctx.marketParams, 0, cut, LENDER, SECOND_BORROWER, LENDER);

        uint128 colAfter = ctx.market.position(ctx.id, SECOND_BORROWER).collateral;
        assertEq(uint256(colAfter), uint256(colBefore) - collateralSeized, "tail collateral debited");
        assertGt(debtCanceled, 0, "tail debt canceled");
        assertEq(collateralSeized, debtCanceled * 1e36 / ctx.price, "oracle-rate cut");
    }

    /// @notice A banned borrower's collateral never settles into `active`, and its borrow is hard-blocked.
    ///         Exercises the guardian-ban path: a ban skips maturation (like a freeze) and hard-blocks the borrow.
    function test_ban_bannedCollateralNeverMaturesAndBorrowBlocked() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        TestMarket memory ctx = _deployMarket(false);

        _mintWETH(ctx.market, LENDER, 10 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");

        uint256 col = _mintWstETH(ctx.market, BORROWER, 20 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col, BORROWER, "");
        _assertCollateralState(ctx.controller, BORROWER, 0, col, 0);

        // Ban BORROWER: one flag reaches quorum 1, which latches the ban. The test contract is the
        // registry's sole guardian (set in `_deployMarket`).
        address[] memory toFlag = new address[](1);
        toFlag[0] = BORROWER;
        IRegistryLike(ctx.guardianSignals)
            .flag(
                ctx.id,
                toFlag,
                BlockInfoWithHash({
                    hash: blockhash(block.number), number: uint40(block.number), timestamp: uint40(block.timestamp)
                })
            );

        // Warp far past any normal activation delay — a banned address never settles.
        vm.warp(block.timestamp + 30 days);
        ILidoLendMarketController.BorrowerPosition memory pv = ctx.controller.positionOf(BORROWER);
        assertTrue(pv.banned, "banned");
        _assertCollateralState(ctx.controller, BORROWER, 0, col, 0); // still activating, never active

        // No active collateral + banned -> borrow reverts.
        vm.prank(BORROWER);
        vm.expectRevert();
        ctx.market.borrow(ctx.marketParams, 1 ether, 0, BORROWER, BORROWER);
    }

    /// @notice The activation delay is inflow-scaled (a larger inflow adds more to the throttle and
    ///         earns a longer delay) and is enforced (collateral does not settle before its unlock).
    function test_maturation_delayScalesWithInflowAndIsEnforced() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        TestMarket memory ctx = _deployMarket(false);

        uint256 smallCol = _mintWstETH(ctx.market, BORROWER, 30 ether);
        uint256 bigCol = _mintWstETH(ctx.market, SECOND_BORROWER, 1000 ether);

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, smallCol, BORROWER, "");
        uint256 smallUnlock = ctx.controller.positionOf(BORROWER).unlockTime;

        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, bigCol, SECOND_BORROWER, "");
        uint256 bigUnlock = ctx.controller.positionOf(SECOND_BORROWER).unlockTime;

        // The bigger inflow piled more onto the inflow accumulator -> strictly longer delay.
        assertGt(bigUnlock, smallUnlock, "bigger inflow -> longer activation delay");
        // The small lot activated (not dust) and, in a near-empty market, matures fast (under the 2h cap).
        assertGt(smallUnlock, block.timestamp, "small deposit activated (not dust)");
        assertLt(smallUnlock - block.timestamp, 2 hours, "small deposit ~ minimum delay");

        // Enforced: while the timer runs the lot is held in `activating`, never borrowable as `active`.
        _assertCollateralState(ctx.controller, BORROWER, 0, smallCol, 0);
    }

    /// @notice A same-tx supplyCollateral -> withdrawCollateral round-trip is inflow-neutral: the deposit's
    ///         inflow addition is reversed on the same-tx withdrawal, so a flash loan cannot pump the inflow.
    function test_flashUndo_sameTxRoundTripIsInflowNeutral() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        TestMarket memory ctx = _deployMarket(false);

        // Seed real inflow with a committed deposit so `currentInflow()` is observably non-zero.
        uint256 seed = _mintWstETH(ctx.market, BORROWER, 30 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, seed, BORROWER, "");
        uint256 inflowBefore = ctx.controller.currentInflow();
        assertGt(inflowBefore, 0, "seed deposit added to inflow");

        // Flash actor supplies and withdraws the same collateral in ONE transaction.
        FlashRoundTrip flasher = new FlashRoundTrip();
        uint256 amount = _mintWstETH(ctx.market, address(flasher), 50 ether);
        flasher.run(ctx.market, ctx.marketParams, amount);

        // No time passed, so no decay: the round-trip must leave the inflow exactly where it was.
        assertEq(ctx.controller.currentInflow(), inflowBefore, "same-tx round-trip is inflow-neutral");
    }

    function _settleAndAssert(TestMarket memory ctx, uint256 borrowerCollateral) internal {
        uint256 sharesToExit = _sliceShares(ctx);

        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            ctx.market.settle(ctx.marketParams, 0, sharesToExit, LENDER, BORROWER, LENDER);

        uint256 expectedCollateralSeized = debtCanceled * 1e36 / ctx.price;
        assertEq(collateralSeized, expectedCollateralSeized, "oracle-rate collateral");
        assertGt(debtCanceled, 0, "settled the allowed slice");
        assertEq(WSTETH.balanceOf(LENDER), collateralSeized, "lender received real wstETH");

        _assertBorrowerCollateralDebited(ctx, borrowerCollateral, collateralSeized);
    }

    /// @dev Loan-asset slice the controller will allow against the current queue root, converted to
    ///      lender supply shares with Morpho's virtual-offset rounding.
    function _sliceShares(TestMarket memory ctx) internal view returns (uint256) {
        (address root,,,) = ctx.controller.nextSettlementBorrower();
        uint256 sliceAssets = ctx.controller.positionOf(root).slice;
        if (sliceAssets == type(uint256).max) return type(uint256).max;
        Market memory _m = ctx.market.market(ctx.id);
        (uint128 totalSupplyAssets, uint128 totalSupplyShares) = (_m.totalSupplyAssets, _m.totalSupplyShares);
        return SharesMathLib.toSharesDown(sliceAssets, uint256(totalSupplyAssets), uint256(totalSupplyShares));
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
        uint128 borrowerRawCollateral = ctx.market.position(ctx.id, BORROWER).collateral;
        assertEq(uint256(borrowerRawCollateral), initialCollateral - collateralSeized, "raw collateral debited");
        _assertCollateralState(ctx.controller, BORROWER, initialCollateral - collateralSeized, 0, 0);
    }

    function _deployMarket(bool enableSettlement) internal returns (TestMarket memory ctx) {
        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: WETH_ADDRESS,
                collateralToken: WSTETH_ADDRESS,
                oracleSource: WSTETH_ADDRESS,
                lltv: LLTV,
                enableSettlement: enableSettlement,
                activation: CollateralActivationConfigParams({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    activatingLockAmount: 0,
                    activatingLockDuration: 0,
                    maxDelayInflow: 10_000 ether,
                    minActivationAmount: 10 ether,
                    maxGuardiansQuorumDelay: 0,
                    delayPerStrike: 0,
                    delayPerSuspect: 0
                }),
                settlementConfig: SettlementConfigParams({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                suspectWindow: 0,
                vaultName: "Lido wstETH/WETH Vault",
                vaultSymbol: "lidoWSTETH-WETH"
            })
        );

        ctx.market = ILidoLend(d.core);
        ctx.controller = ILidoLendMarketController(d.controllerProxy);
        ctx.guardianSignals = d.guardianSignals;
        ctx.marketParams = d.params;
        ctx.id = d.marketId;
        ctx.price = WstEthRateOracle(d.oracle).price();

        ctx.controller.grantRole(ctx.controller.MANAGER_ROLE(), address(this));
    }

    function _mintWETH(ILidoLend market, address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        WETH.deposit{value: amount}();
        vm.prank(user);
        WETH.approve(address(market), type(uint256).max);
    }

    function _mintWstETH(ILidoLend market, address user, uint256 ethAmount) internal returns (uint256) {
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

    function _assertCollateralState(
        ILidoLendMarketController controller,
        address borrower,
        uint256 matured,
        uint256 activating,
        uint256 dust
    ) internal view {
        ILidoLendMarketController.BorrowerPosition memory pv = controller.positionOf(borrower);
        assertEq(pv.active, matured, "matured (active) collateral");
        assertEq(pv.activating, activating, "maturing (activating) collateral");
        assertEq(pv.dust, dust, "dust collateral");
    }
}
