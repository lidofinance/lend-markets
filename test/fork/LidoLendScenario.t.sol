// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Position, Market} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

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

/// @dev Runs a supplyCollateral -> withdrawCollateral round-trip in ONE call frame (one tx), so the
///      controller's same-tx flash-undo fires. Holds the collateral and is its own onBehalf/receiver.
contract FlashRoundTrip {
    function run(ILidoLend market, MarketParams calldata params, uint256 amount) external {
        market.supplyCollateral(params, amount, address(this), "");
        market.withdrawCollateral(params, amount, address(this), address(this));
    }
}

/// @notice End-to-end scenarios over the ALREADY-DEPLOYED, ALREADY-ACTIVATED `weth-wsteth` market (bound via
///         {ForkStack}, never re-deployed): activation / dust promotion, instant activation, the open-debt
///         collateral floor, the settle queue (heap ordering, settlement LTV, the bad-debt guard), the maturation
///         delay's inflow scaling, and same-tx flash-undo neutrality. Drives supply / borrow / maturation and the
///         settlement hooks against the live core + controller + vault + oracle + guardian registry.
///
///         State-robustness / live-config contract (a shared deployed market may already carry supply / borrow and
///         real governance config):
///           - actors are fresh and market-clean (`_freshActor`), so every per-actor read doubles as a delta;
///           - lender liquidity is gated by `_requireDepositHeadroom` and shaped with `_pinFreeLiquidity` (measured,
///             never assumed) so a pre-existing supply / borrow cannot starve a borrow or block a settle;
///           - every settle-queue test loudly requires the intended queue root before cutting, so a pre-existing
///             riskier borrower cannot silently hijack the slice;
///           - price rebases are mocked RELATIVE to the test position (the exact `getStETHByWstETH(1e36)` call the
///             oracle makes) so the borrower lands in the intended LTV band at ANY live wstETH rate, and every
///             expected number recomputes from the mocked / live price;
///           - guardian bans run through the REAL committee (`getGuardians` / `getQuorum`), not a test-owned set;
///           - collateral / deposit sizing derives from the live oracle price, `minActivationAmount`, and LLTV.
contract LidoLendScenarioTest is ForkStack {
    BoundMarket internal m;

    address internal WETH_ADDRESS;
    address internal STETH_ADDRESS;
    address internal WSTETH_ADDRESS;

    IWETH internal WETH;
    IStETH internal STETH;
    IWstETH internal WSTETH;

    // Fresh, market-clean actors (start at zero position and zero vault shares), so per-actor reads are deltas.
    address internal LENDER;
    address internal BORROWER;
    address internal SECOND_BORROWER;
    address internal DONOR;
    address internal THIRD_BORROWER;

    /// @notice The suite's view of the bound market, rebuilt per test so the bodies read like the freshly-deployed
    ///         variant did. `price` is the LIVE oracle rate captured before any mock.
    struct TestMarket {
        ILidoLend market;
        ILidoLendMarketController controller;
        MarketParams marketParams;
        Id id;
        uint256 price;
    }

    function setUp() public {
        _fork();
        m = _bindMarket("fork-weth-wsteth");
        _pokeAccrue(m); // fold in pending interest up front so exact totals / delta math below holds
        _grantSelfManager(m); // regain MANAGER_ROLE so `grantInstantActivation` call sites stay unchanged

        WETH_ADDRESS = address(m.loanToken);
        STETH_ADDRESS = _ext("stEth");
        WSTETH_ADDRESS = address(m.collateralToken);
        WETH = IWETH(WETH_ADDRESS);
        STETH = IStETH(STETH_ADDRESS);
        WSTETH = IWstETH(WSTETH_ADDRESS);

        LENDER = _freshActor(m, "scenario.lender");
        BORROWER = _freshActor(m, "scenario.borrower");
        SECOND_BORROWER = _freshActor(m, "scenario.second");
        DONOR = _freshActor(m, "scenario.donor");
        THIRD_BORROWER = _freshActor(m, "scenario.third");
    }

    /// @dev A sub-threshold (dust) deposit is promoted to activating once a top-up crosses the activation minimum,
    ///      matures after the delay, then borrows real WETH against the now-active collateral. Dust lots are sized
    ///      from the LIVE `minActivationAmount` (each below it, the pair above it), so the promotion holds at any
    ///      live wstETH rate.
    function test_supplyCollateral_promotesDustAndBorrowsAfterMaturity() public {
        TestMarket memory ctx = _ctx();

        uint256 dustEach = uint256(m.activation.minActivationAmount) * 6 / 10; // each below the threshold
        uint256 borrowerDust = _dealWstETH(BORROWER, dustEach);
        uint256 donorTopUp = _dealWstETH(DONOR, dustEach);
        uint256 activatedCollateral = borrowerDust + donorTopUp; // the pair clears the threshold once combined

        _requireDepositHeadroom(m, 10 ether);
        _mintWETH(ctx.market, LENDER, 10 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, borrowerDust, BORROWER, "");
        _assertCollateralState(ctx.controller, BORROWER, 0, 0, borrowerDust);

        vm.prank(DONOR);
        ctx.market.supplyCollateral(ctx.marketParams, donorTopUp, BORROWER, "");
        _assertCollateralState(ctx.controller, BORROWER, 0, activatedCollateral, 0);

        _warpPastActivation(m);

        vm.prank(BORROWER);
        (uint256 borrowedAssets,) = ctx.market.borrow(ctx.marketParams, 3 ether, 0, BORROWER, BORROWER);

        assertEq(borrowedAssets, 3 ether, "borrowed after maturity");
        assertEq(WETH.balanceOf(BORROWER), 3 ether, "borrower received real WETH");
        _assertCollateralState(ctx.controller, BORROWER, activatedCollateral, 0, 0);
    }

    /// @notice Instant activation (whitelist): a trusted borrower's collateral is active on deposit, so it
    ///         borrows with no maturation wait. Revoking restores the timer for fresh deposits.
    function test_instantActivation_skipsMaturationDelay() public {
        TestMarket memory ctx = _ctx();
        ctx.controller.grantInstantActivation(BORROWER);
        assertTrue(ctx.controller.hasInstantActivation(BORROWER), "borrower whitelisted");

        _requireDepositHeadroom(m, 10 ether);
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
    ///         lifts the constraint. Amounts derive from the LIVE threshold.
    function test_withdraw_collateralFloorWithOpenDebt() public {
        TestMarket memory ctx = _ctx();
        uint256 min = uint256(m.activation.minActivationAmount);
        uint256 aboveFloor = min + 1 ether; // the smallest lot the floor still permits with open debt

        _requireDepositHeadroom(m, 10 ether);
        _mintWETH(ctx.market, LENDER, 10 ether);
        uint256 col = _mintWstETH(ctx.market, BORROWER, 18 ether); // comfortably above the threshold
        assertGt(col, aboveFloor + 1 ether, "collateral above the threshold for the test");

        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col, BORROWER, "");
        _warpPastActivation(m);

        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 2 ether, 0, BORROWER, BORROWER);

        // Down to just above the threshold is allowed (health is loose, so the threshold is what binds).
        vm.prank(BORROWER);
        ctx.market.withdrawCollateral(ctx.marketParams, col - aboveFloor, BORROWER, BORROWER);

        // The next 2 wstETH would drop active collateral below the threshold with open debt: zero capacity, reverts.
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        ctx.market.withdrawCollateral(ctx.marketParams, 2 ether, BORROWER, BORROWER);

        // Repay the debt to zero, then the floor no longer applies and the rest comes out.
        _mintWETH(ctx.market, BORROWER, 3 ether);
        uint128 borrowShares = ctx.market.position(ctx.id, BORROWER).borrowShares;
        vm.prank(BORROWER);
        ctx.market.repay(ctx.marketParams, 0, borrowShares, BORROWER, "");
        vm.prank(BORROWER);
        ctx.market.withdrawCollateral(ctx.marketParams, aboveFloor, BORROWER, BORROWER);
    }

    /// @notice Collateral floor on borrow: a position whose active collateral is below the activation threshold
    ///         cannot open debt — its borrow capacity is zero. Symmetric to the withdraw case, but binds before
    ///         any debt exists.
    function test_borrow_belowPositionFloorReverts() public {
        TestMarket memory ctx = _ctx();
        uint256 belowFloor = uint256(m.activation.minActivationAmount) / 2; // half the threshold: sub-threshold

        _requireDepositHeadroom(m, 10 ether);
        _mintWETH(ctx.market, LENDER, 10 ether);
        uint256 col = _mintWstETH(ctx.market, BORROWER, 18 ether); // above the threshold
        assertGt(col, belowFloor + 2 ether, "collateral above the threshold for the test");

        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col, BORROWER, "");
        _warpPastActivation(m);

        // No debt yet, so the withdraw health gate does not bind: draw active collateral below the threshold.
        vm.prank(BORROWER);
        ctx.market.withdrawCollateral(ctx.marketParams, col - belowFloor, BORROWER, BORROWER);
        _assertCollateralState(ctx.controller, BORROWER, belowFloor, 0, 0); // active collateral below the threshold

        // Sub-threshold active collateral has zero borrow capacity, so the borrow reverts. (Draw above the
        // dust-market floor: a 1-wei borrow would trip that floor first, before reaching the capacity gate.)
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        ctx.market.borrow(ctx.marketParams, 1 ether, 0, BORROWER, BORROWER);
    }

    /// @dev Happy-path settle: with two active borrowers, cutting the allowed slice against the queue root seizes
    ///      collateral at the oracle rate and pays the lender real wstETH. The root borrower's debt is sized near
    ///      the LLTV ceiling so it is the queue root over the second borrower and the over-collateralized
    ///      liquidity-pin borrower.
    function test_settle_happyPath() public {
        TestMarket memory ctx = _ctx();

        uint256 borrowerCollateral = _mintWstETH(ctx.market, BORROWER, 20 ether);
        uint256 secondBorrowerCollateral = _mintWstETH(ctx.market, SECOND_BORROWER, 20 ether);

        uint256 borrowerDebt = _maxBorrow(borrowerCollateral, ctx.price) * 85 / 100; // near-LLTV: queue root
        uint256 secondBorrowerDebt = _maxBorrow(secondBorrowerCollateral, ctx.price) * 20 / 100; // low LTV: tail

        uint256 lend = borrowerDebt + secondBorrowerDebt + 2 ether;
        _requireDepositHeadroom(m, lend);
        _mintWETH(ctx.market, LENDER, lend);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, borrowerCollateral, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, secondBorrowerCollateral, SECOND_BORROWER, "");

        _warpPastActivation(m);

        assertTrue(borrowerDebt < _maxBorrow(borrowerCollateral, ctx.price), "borrower debt under LLTV");
        assertTrue(secondBorrowerDebt < _maxBorrow(secondBorrowerCollateral, ctx.price), "second debt under LLTV");

        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, borrowerDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, secondBorrowerDebt, 0, SECOND_BORROWER, SECOND_BORROWER);

        _assertCollateralState(ctx.controller, BORROWER, borrowerCollateral, 0, 0);
        _assertCollateralState(ctx.controller, SECOND_BORROWER, secondBorrowerCollateral, 0, 0);

        // Drain free liquidity to zero so the lender's cut must go through settle, then require the test borrower
        // is the queue root — a pre-existing riskier borrower would otherwise take the slice.
        _pinFreeLiquidity(m, 0);
        (address root,,,) = ctx.controller.nextSettlementBorrower();
        require(root == BORROWER, "settle_happyPath: a pre-existing riskier borrower outranks the test borrower");

        _settleAndAssert(ctx, borrowerCollateral);
    }

    /// @notice One scenario exercising the heap-driven settle ordering end-to-end.
    /// @dev Covers, in order:
    ///        - three borrowers at different risk levels; queue root tracks the highest-LTV one;
    ///        - a cut targeting the root reduces it but does not flip the order;
    ///        - the root opts another borrower in via a settlement LTV, so a non-root cut succeeds;
    ///        - the lowest-LTV borrower is never touched throughout the scenario.
    function test_settle_heapPicksTopBorrower() public {
        TestMarket memory ctx = _ctx();

        uint256 countBefore = ctx.controller.settlementBorrowersCount();

        uint256 highCol = _mintWstETH(ctx.market, BORROWER, 20 ether);
        uint256 midCol = _mintWstETH(ctx.market, SECOND_BORROWER, 20 ether);
        uint256 lowCol = _mintWstETH(ctx.market, THIRD_BORROWER, 20 ether);

        uint256 highDebt = _maxBorrow(highCol, ctx.price) * 85 / 100; // near-LLTV: queue root
        uint256 midDebt = _maxBorrow(midCol, ctx.price) * 45 / 100;
        uint256 lowDebt = _maxBorrow(lowCol, ctx.price) * 15 / 100;

        // Lender saturates the market so every cut below has to go through settle and not the ordinary withdraw path.
        uint256 lend = highDebt + midDebt + lowDebt + 2 ether;
        _requireDepositHeadroom(m, lend);
        _mintWETH(ctx.market, LENDER, lend);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, highCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, midCol, SECOND_BORROWER, "");
        vm.prank(THIRD_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, lowCol, THIRD_BORROWER, "");

        _warpPastActivation(m);

        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, highDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, midDebt, 0, SECOND_BORROWER, SECOND_BORROWER);
        vm.prank(THIRD_BORROWER);
        ctx.market.borrow(ctx.marketParams, lowDebt, 0, THIRD_BORROWER, THIRD_BORROWER);

        // (1) Initial queue order: the three test borrowers are all tracked and the highest-LTV one is at the root.
        assertEq(ctx.controller.settlementBorrowersCount(), countBefore + 3, "all three active borrowers tracked");
        (address root,,,) = ctx.controller.nextSettlementBorrower();
        assertEq(root, BORROWER, "highest-LTV borrower at root");

        // Saturate to zero free liquidity so the cuts below settle (adds an over-collateralized pin borrower that
        // ranks below the near-LLTV root, leaving the queue order intact).
        _pinFreeLiquidity(m, 0);
        (root,,,) = ctx.controller.nextSettlementBorrower();
        require(root == BORROWER, "settle_heap: pin disturbed the queue root");

        // (2) A partial cut on the root, half the allowed slice. Cutting half reduces the root's key without
        //     flipping it below the runner-up.
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
    /// @dev Setup: a high-LTV root (BORROWER) and a healthy tail (SECOND_BORROWER). A negative rebase — sized
    ///      RELATIVE to the root's own debt / collateral so it lands underwater at any live rate — pushes the root
    ///      insolvent (debt > collateral value). Cutting the healthy tail must also revert while the root is
    ///      insolvent — the whole queue halts until bad debt is resolved.
    function testRevert_settle_whenHeapRootBadDebt() public {
        TestMarket memory ctx = _ctx();

        uint256 headCol = _mintWstETH(ctx.market, BORROWER, 25 ether);
        uint256 tailCol = _mintWstETH(ctx.market, SECOND_BORROWER, 25 ether);

        uint256 headDebt = _maxBorrow(headCol, ctx.price) * 85 / 100; // near the LLTV ceiling: queue root
        uint256 tailDebt = _maxBorrow(tailCol, ctx.price) * 10 / 100; // healthy tail

        uint256 lend = headDebt + tailDebt + 2 ether;
        _requireDepositHeadroom(m, lend);
        _mintWETH(ctx.market, LENDER, lend);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, headCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, tailCol, SECOND_BORROWER, "");

        _warpPastActivation(m);

        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, headDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, tailDebt, 0, SECOND_BORROWER, SECOND_BORROWER);

        // Precondition at the LIVE rate: the test borrower heads the queue and nobody is bad debt yet.
        (address root,,,) = ctx.controller.nextSettlementBorrower();
        assertEq(root, BORROWER, "high-LTV borrower is the queue head");
        require(
            !ctx.controller.hasBadDebt(), "settle_badDebt: a pre-existing borrower is already bad debt at live rate"
        );

        // Drain free liquidity to zero (at the live rate) so the successful settle below reaches collateral.
        _pinFreeLiquidity(m, 0);

        // Cut sized to the allowed slice at the real rate (reused after the rebase is cleared).
        uint256 cut = _sliceShares(ctx) / 2;

        // Negative rebase RELATIVE to the head's position: drop the wstETH rate so the head's collateral is worth
        // ~10% less than its debt (bad debt) regardless of the live rate. The tail stays healthy.
        uint256 headDebtAssets = ctx.controller.positionOf(BORROWER).debtAssets;
        uint256 headRawCollateral = ctx.market.position(ctx.id, BORROWER).collateral;
        uint256 badDebtPrice = Math.mulDiv(headDebtAssets, ORACLE_PRICE_SCALE, headRawCollateral) * 9 / 10;
        vm.mockCall(
            WSTETH_ADDRESS,
            abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector, ORACLE_PRICE_SCALE),
            abi.encode(badDebtPrice)
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
        (root,,,) = ctx.controller.nextSettlementBorrower();
        require(root == BORROWER, "settle_badDebt: root drifted off the test borrower after restore");
        vm.prank(LENDER);
        ctx.market.settle(ctx.marketParams, 0, cut, LENDER, BORROWER, LENDER);
    }

    /// @notice Settle works on an unhealthy-but-solvent position (LLTV < LTV < 100%).
    /// @dev Soft-liquidation must reach risky positions, not just healthy ones. A negative rebase — sized RELATIVE
    ///      to the borrower's own position so it lands at a post-rebase LTV inside (LLTV, 1) at any live rate AND
    ///      any live LLTV — pushes the borrower above LLTV (unhealthy) while keeping their collateral worth more
    ///      than their debt (solvent).
    function test_settle_worksOnUnhealthyButSolventPosition() public {
        TestMarket memory ctx = _ctx();

        uint256 col = _mintWstETH(ctx.market, BORROWER, 25 ether);
        uint256 borrowAmount = _maxBorrow(col, ctx.price) * 85 / 100; // near-LLTV, healthy at the live rate

        uint256 lend = borrowAmount + 2 ether;
        _requireDepositHeadroom(m, lend);
        _mintWETH(ctx.market, LENDER, lend);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col, BORROWER, "");
        _warpPastActivation(m);
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, borrowAmount, 0, BORROWER, BORROWER);

        (address root,,,) = ctx.controller.nextSettlementBorrower();
        require(root == BORROWER, "settle_unhealthy: a pre-existing riskier borrower outranks the test borrower");
        _pinFreeLiquidity(m, 0);

        // Negative rebase RELATIVE to the position: land BORROWER halfway between the live LLTV and 100% — above
        // LLTV (unhealthy), below 100% (solvent) — whatever the live rate AND whatever the market's LLTV. Derived,
        // not fixed: a hardcoded 90% is only unhealthy on a market whose LLTV is below it.
        // `price = debt / (collateral * targetLtv)`.
        uint256 debtAssets = ctx.controller.positionOf(BORROWER).debtAssets;
        uint256 rc = ctx.market.position(ctx.id, BORROWER).collateral;
        uint256 targetLtv = ctx.marketParams.lltv + (WAD - ctx.marketParams.lltv) / 2;
        uint256 droppedPrice = Math.mulDiv(debtAssets, WAD * ORACLE_PRICE_SCALE, rc * targetLtv);
        vm.mockCall(
            WSTETH_ADDRESS,
            abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector, ORACLE_PRICE_SCALE),
            abi.encode(droppedPrice)
        );

        assertLt(droppedPrice, ctx.price, "rebase is negative");
        assertGt(debtAssets, _maxBorrow(rc, droppedPrice), "position is unhealthy (LTV > LLTV)");
        assertGt(Math.mulDiv(rc, droppedPrice, ORACLE_PRICE_SCALE), debtAssets, "position is solvent (value > debt)");
        assertFalse(ctx.controller.hasBadDebt(), "head is not bad debt");

        // The cut succeeds even though the borrower is unhealthy. Slice sized from the mocked-price policy slice.
        uint256 cut = _sliceShares(ctx) / 2;
        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            ctx.market.settle(ctx.marketParams, 0, cut, LENDER, BORROWER, LENDER);

        assertGt(debtCanceled, 0, "debt cancelled");
        assertEq(collateralSeized, debtCanceled * ORACLE_PRICE_SCALE / droppedPrice, "collateral seized at oracle rate");
        uint128 rcAfter = ctx.market.position(ctx.id, BORROWER).collateral;
        assertEq(uint256(rcAfter), rc - collateralSeized, "borrower collateral debited");
    }

    /// @notice setSettlementLtv stores the borrower's target LTV; rejects ltv >= 1e18.
    function test_setSettlementLtv_storesAndRejectsOutOfRange() public {
        TestMarket memory ctx = _ctx();

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
        TestMarket memory ctx = _ctx();

        // Collateral sized so the post-cut remainder stays above the activation minimum, keeping the
        // settlement-LTV slice off the dust-extension clamp (which would promote it to the full debt).
        uint256 hotCol = _mintWstETH(ctx.market, BORROWER, 30 ether);
        uint256 coldCol = _mintWstETH(ctx.market, SECOND_BORROWER, 30 ether);

        // Close LTVs -> small key gap -> small algorithmic slice; BORROWER a hair higher so it heads the queue.
        uint256 hotDebt = _maxBorrow(hotCol, ctx.price) * 75 / 100;
        uint256 coldDebt = _maxBorrow(coldCol, ctx.price) * 71 / 100;

        uint256 lend = hotDebt + coldDebt + 2 ether;
        _requireDepositHeadroom(m, lend);
        _mintWETH(ctx.market, LENDER, lend);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, hotCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, coldCol, SECOND_BORROWER, "");

        _warpPastActivation(m);
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, hotDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, coldDebt, 0, SECOND_BORROWER, SECOND_BORROWER);

        (address rootBefore,,,) = ctx.controller.nextSettlementBorrower();
        require(rootBefore == BORROWER, "settlementLtv_bump: a pre-existing riskier borrower heads the queue");
        uint256 sliceBefore = ctx.controller.positionOf(rootBefore).slice;

        // BORROWER opts in to a 30% post-cut LTV — a deep target.
        vm.prank(BORROWER);
        ctx.controller.setSettlementLtv(0.3e18);

        (address rootAfter,,,) = ctx.controller.nextSettlementBorrower();
        uint256 sliceAfter = ctx.controller.positionOf(rootAfter).slice;
        assertEq(rootAfter, BORROWER, "root unchanged");
        assertGt(sliceAfter, sliceBefore, "settlement LTV raised the slice");

        // Settlement-LTV slice closed form: c = (D*WAD - W*V) / (WAD - W), with V = col * price / 1e36, recomputed
        // from the live position and price.
        uint256 debt = ctx.controller.positionOf(BORROWER).debtAssets;
        uint256 colValue = Math.mulDiv(hotCol, ctx.price, ORACLE_PRICE_SCALE);
        uint256 expected = (debt * WAD - 0.3e18 * colValue) / (WAD - 0.3e18);
        assertApproxEqAbs(sliceAfter, expected, 1e15, "slice matches settlement-LTV formula");
    }

    /// @notice Direct EOA-lender can settle a non-root borrower iff that borrower has a personal
    ///         settlement LTV set. Without one its policy slice is zero, so the controller hook reverts
    ///         `SettlementExceedsAllowed` on any cut.
    function test_settle_eligibleViaPersonalSettlementLtv() public {
        TestMarket memory ctx = _ctx();

        _requireDepositHeadroom(m, 10 ether);
        _mintWETH(ctx.market, LENDER, 10 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");

        // Two borrowers, BORROWER higher LTV than SECOND_BORROWER. Total borrow drains the supply so the lender's
        // exit must trigger settle.
        uint256 col1 = _mintWstETH(ctx.market, BORROWER, 20 ether);
        uint256 col2 = _mintWstETH(ctx.market, SECOND_BORROWER, 20 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col1, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col2, SECOND_BORROWER, "");

        _warpPastActivation(m);
        vm.prank(BORROWER);
        ctx.market.borrow(ctx.marketParams, 7 ether, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        ctx.market.borrow(ctx.marketParams, 3 ether, 0, SECOND_BORROWER, SECOND_BORROWER);

        _pinFreeLiquidity(m, 0);

        // The mechanism only needs SECOND_BORROWER NOT to be the queue root: as a non-root borrower its policy slice
        // is zero, so eligibility must come from its personal settlement LTV, not from heading the queue.
        (address root,,,) = ctx.controller.nextSettlementBorrower();
        require(root != SECOND_BORROWER, "settle_personalLtv: tail borrower unexpectedly heads the queue");

        uint256 lenderShares = ctx.market.position(ctx.id, LENDER).supplyShares;
        uint256 cut = lenderShares / 5;

        // Targeting tail SECOND_BORROWER without a settlement LTV -> zero slice -> hook revert.
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
        assertEq(collateralSeized, debtCanceled * ORACLE_PRICE_SCALE / ctx.price, "oracle-rate cut");
    }

    /// @notice A banned borrower's collateral never settles into `active`, and its borrow is hard-blocked.
    ///         Exercises the guardian-ban path: a ban skips maturation (like a freeze) and hard-blocks the borrow.
    ///         Runs through the REAL guardian committee read from the deployed registry.
    function test_ban_bannedCollateralNeverMaturesAndBorrowBlocked() public {
        TestMarket memory ctx = _ctx();

        _requireDepositHeadroom(m, 10 ether);
        _mintWETH(ctx.market, LENDER, 10 ether);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, 10 ether, 0, LENDER, "");

        uint256 col = _mintWstETH(ctx.market, BORROWER, 20 ether);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, col, BORROWER, "");
        _assertCollateralState(ctx.controller, BORROWER, 0, col, 0);

        // Ban BORROWER through the REAL committee: flag on behalf of a quorum of distinct guardians, which latches
        // the ban. The test contract is not a guardian on the deployed registry, so we prank the live set.
        (address[] memory guardians,) = m.guardianSignals.getGuardians();
        uint256 quorum = m.guardianSignals.getQuorum();
        require(guardians.length >= quorum, "ban: live guardian set smaller than its quorum");
        address[] memory toFlag = new address[](1);
        toFlag[0] = BORROWER;
        for (uint256 i; i < quorum; ++i) {
            vm.prank(guardians[i]);
            m.guardianSignals.flag(ctx.id, guardians[i], toFlag);
        }

        // Warp far past any normal activation delay — a banned address never settles.
        vm.warp(block.timestamp + 30 days);
        ILidoLendMarketController.BorrowerPosition memory pv = ctx.controller.positionOf(BORROWER);
        assertTrue(pv.banned, "banned");
        _assertCollateralState(ctx.controller, BORROWER, 0, col, 0); // still activating, never active

        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        ctx.market.borrow(ctx.marketParams, 1 ether, 0, BORROWER, BORROWER);
    }

    /// @notice The activation delay is inflow-scaled (a larger inflow adds more to the throttle and
    ///         earns a longer delay) and is enforced (collateral does not settle before its unlock).
    /// @dev Reworked to be state-robust: instead of assuming a near-empty market, it reads the controller's own
    ///      delay predictor for each lot BEFORE supplying and asserts each lot's unlock lands exactly on
    ///      `supplyTs + predictedDelay`. A loud precondition rejects an already-saturated inflow (which would
    ///      collapse both predictions to the delay cap and make the comparison vacuous).
    function test_maturation_delayScalesWithInflowAndIsEnforced() public {
        TestMarket memory ctx = _ctx();

        uint256 smallCol = uint256(m.activation.minActivationAmount) * 5 / 2; // clears the dust floor
        uint256 bigCol = smallCol * 32; // a much larger inflow, still well under `maxDelayInflow`

        // Predict each lot's delay from the controller: the small lot at the current inflow, the big lot at the
        // inflow the small lot leaves behind (same block, no decay, so the increment folds into the sum).
        uint256 dSmall = ctx.controller.currentActivationDelay(smallCol);
        uint256 dBig = ctx.controller.currentActivationDelay(smallCol + bigCol);
        require(dSmall < uint256(m.activation.maxActivationDelay), "maturation: inflow throttle already saturated");

        uint256 ts = block.timestamp;
        _dealWstETH(BORROWER, smallCol);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, smallCol, BORROWER, "");
        uint256 smallUnlock = ctx.controller.positionOf(BORROWER).unlockTime;

        _dealWstETH(SECOND_BORROWER, bigCol);
        vm.prank(SECOND_BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, bigCol, SECOND_BORROWER, "");
        uint256 bigUnlock = ctx.controller.positionOf(SECOND_BORROWER).unlockTime;

        // Each lot's unlock is exactly its supply time plus the predicted, inflow-scaled delay (same block).
        assertEq(smallUnlock, ts + dSmall, "small lot unlock == supply ts + predicted delay");
        assertEq(bigUnlock, ts + dBig, "big lot unlock == supply ts + predicted delay");
        // The bigger inflow piled more onto the inflow accumulator -> strictly longer delay.
        assertGt(bigUnlock, smallUnlock, "bigger inflow -> longer activation delay");
        // The small lot activated (not dust) and matures under the delay cap.
        assertGt(smallUnlock, ts, "small deposit activated (not dust)");

        // Enforced: while the timer runs the lot is held in `activating`, never borrowable as `active`.
        _assertCollateralState(ctx.controller, BORROWER, 0, smallCol, 0);
    }

    /// @notice A same-tx supplyCollateral -> withdrawCollateral round-trip is inflow-neutral: the deposit's
    ///         inflow addition is reversed on the same-tx withdrawal, so a flash loan cannot pump the inflow.
    function test_flashUndo_sameTxRoundTripIsInflowNeutral() public {
        TestMarket memory ctx = _ctx();

        // Seed real inflow with a committed deposit so `currentInflow()` is observably non-zero.
        uint256 seed = _dealWstETH(BORROWER, uint256(m.activation.minActivationAmount) * 5 / 2);
        vm.prank(BORROWER);
        ctx.market.supplyCollateral(ctx.marketParams, seed, BORROWER, "");
        uint256 inflowBefore = ctx.controller.currentInflow();
        assertGt(inflowBefore, 0, "seed deposit added to inflow");

        // Flash actor supplies and withdraws the same collateral in ONE transaction.
        FlashRoundTrip flasher = new FlashRoundTrip();
        uint256 amount = _dealWstETH(address(flasher), uint256(m.activation.minActivationAmount) * 4);
        flasher.run(ctx.market, ctx.marketParams, amount);

        // No time passed, so no decay: the round-trip must leave the inflow exactly where it was.
        assertEq(ctx.controller.currentInflow(), inflowBefore, "same-tx round-trip is inflow-neutral");
    }

    // ---
    // HELPERS
    // ---

    /// @dev Rebuild the suite's market context from the bound market. `price` is the LIVE oracle rate, captured
    ///      before any per-test mock.
    function _ctx() internal view returns (TestMarket memory ctx) {
        ctx.market = m.core;
        ctx.controller = m.controller;
        ctx.marketParams = m.params;
        ctx.id = m.id;
        ctx.price = m.oracle.price();
    }

    function _settleAndAssert(TestMarket memory ctx, uint256 borrowerCollateral) internal {
        uint256 sharesToExit = _sliceShares(ctx);

        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            ctx.market.settle(ctx.marketParams, 0, sharesToExit, LENDER, BORROWER, LENDER);

        uint256 expectedCollateralSeized = debtCanceled * ORACLE_PRICE_SCALE / ctx.price;
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

    /// @dev Largest debt (loan assets) borrowable against `collateral` at `price`, at the live market LLTV.
    function _maxBorrow(uint256 collateral, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(collateral, price, ORACLE_PRICE_SCALE), m.params.lltv, WAD);
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

    /// @dev Give `user` an exact wstETH amount and approve the core. Used where the test needs a collateral lot
    ///      sized precisely against the LIVE dust floor / inflow accumulator (a real stETH `submit`/`wrap` would
    ///      only approximate the target and swing with the live rate).
    function _dealWstETH(address user, uint256 wstAmount) internal returns (uint256) {
        deal(WSTETH_ADDRESS, user, wstAmount);
        vm.prank(user);
        WSTETH.approve(address(m.core), type(uint256).max);
        return wstAmount;
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
