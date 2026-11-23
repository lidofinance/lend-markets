// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Position, Market as MarketState} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementSlice} from "../../src/types/SettlementTypes.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {ForkStack} from "./helpers/ForkStack.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Runs a supplyCollateral -> withdrawCollateral round-trip in ONE call frame (one tx), so the
///      controller's same-tx flash-undo fires. Holds the collateral and is its own onBehalf/receiver.
contract FlashRoundTrip {
    function run(ILidoLend market, MarketParams calldata params, uint256 amount) external {
        market.supplyCollateral(params, amount, address(this), "");
        market.withdrawCollateral(params, amount, address(this), address(this));
    }
}

/// @notice End-to-end scenarios over the bound market (see {ForkStack}): activation / dust promotion, instant
/// activation, the open-debt collateral floor, the settle queue (heap ordering, settlement LTV, the bad-debt guard),
/// the maturation
///         delay's inflow scaling, and same-tx flash-undo neutrality. Drives supply / borrow / maturation and the
///         settlement hooks against the live core + controller + vault + oracle + guardian registry.
///
///         State-robustness / live-config contract (a shared deployed market may already carry supply / borrow and
///         real governance config):
///           - actors are fresh and market-clean (`_freshActor`), so every per-actor read doubles as a delta;
///           - lender liquidity is gated by `_requireSupplyHeadroom` and shaped with `_setFreeLiquidity` (measured,
///             never assumed) so a pre-existing supply / borrow cannot starve a borrow or block a settle;
///           - every settle-queue test loudly requires the intended queue root before cutting, so a pre-existing
///             riskier borrower cannot silently hijack the slice;
///           - price falls are mocked RELATIVE to the test position, through the oracle's own source, so the
///             borrower lands in the intended LTV band at ANY live price, and every expected number recomputes
///             from the mocked / live price;
///           - guardian bans run through the REAL committee (`getGuardians` / `getQuorum`), not a test-owned set;
///           - collateral / deposit sizing derives from the live oracle price, `minActivationAmount`, and LLTV; fixed
///             amounts are counted in `C`, a tenth of `minActivationAmount`, and `L`, the same count of loan tokens.
contract LidoLendScenarioTest is ForkStack {
    /// @dev The collateral unit, a tenth of the live `minActivationAmount`, and the loan unit, the same count of loan
    ///      tokens: one ether each on WETH/wstETH.
    uint256 internal C;
    uint256 internal L;

    // Fresh, market-clean actors (start at zero position and zero vault shares), so per-actor reads are deltas.
    address internal SECOND_BORROWER;
    address internal DONOR;
    address internal THIRD_BORROWER;

    /// @notice The suite's view of the bound market, rebuilt per test so the bodies read like the freshly-deployed
    ///         variant did. `price` is the LIVE oracle rate captured before any mock.

    function setUp() public {
        _onlyOnOneMarketPerKind();
        _setUpTarget();
        _accrueInterest(); // fold in pending interest up front so exact totals / delta math below holds
        _repayExistingBorrowers(); // a live borrower must not outrank or outlast the test's borrowers

        C = uint256(_activationConfig(market).minActivationAmount) / 10;
        L = C * 10 ** IERC20Metadata(address(market.loanToken)).decimals() / 10
            ** IERC20Metadata(address(market.collateralToken)).decimals();

        LENDER = _freshActor(market, "scenario.lender");
        BORROWER = _freshActor(market, "scenario.borrower");
        SECOND_BORROWER = _freshActor(market, "scenario.second");
        DONOR = _freshActor(market, "scenario.donor");
        THIRD_BORROWER = _freshActor(market, "scenario.third");
    }

    /// @dev A sub-threshold (dust) deposit is promoted to activating once a top-up crosses the activation minimum,
    ///      matures after the delay, then borrows the loan token against the now-active collateral. Dust lots are sized
    ///      from the LIVE `minActivationAmount` (each below it, the pair above it), so the promotion holds at any
    ///      live price.
    function test_supplyCollateral_promotesDustAndBorrowsAfterMaturity() public {
        uint256 livePrice = market.oracle.price();

        uint256 dustEach = uint256(_activationConfig(market).minActivationAmount) * 6 / 10; // each below the threshold
        uint256 borrowerDust = _dealCol(BORROWER, dustEach);
        uint256 donorTopUp = _dealCol(DONOR, dustEach);
        uint256 activatedCollateral = borrowerDust + donorTopUp; // the pair clears the threshold once combined

        // The borrow scales with the collateral, which scales with the live threshold. A fixed amount here would
        // exceed capacity the moment governance lowered `minActivationAmount`, and fail as a capacity error
        // rather than telling us anything about promotion.
        uint256 borrowAmount = _maxBorrow(market, activatedCollateral, livePrice) / 4;
        uint256 lend = borrowAmount * 2;

        _requireSupplyHeadroom(market, lend);
        _dealLoan(LENDER, lend);
        vm.prank(LENDER);
        market.core.supply(market.params, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, borrowerDust, BORROWER, "");
        _assertCollateralState(market.controller, BORROWER, 0, 0, borrowerDust);

        vm.prank(DONOR);
        market.core.supplyCollateral(market.params, donorTopUp, BORROWER, "");
        _assertCollateralState(market.controller, BORROWER, 0, activatedCollateral, 0);

        _warpPastActivation();

        vm.prank(BORROWER);
        (uint256 borrowedAssets,) = market.core.borrow(market.params, borrowAmount, 0, BORROWER, BORROWER);

        assertEq(borrowedAssets, borrowAmount, "borrowed after maturity");
        assertEq(market.loanToken.balanceOf(BORROWER), borrowAmount, "borrower received the loan token");
        _assertCollateralState(market.controller, BORROWER, activatedCollateral, 0, 0);
    }

    /// @notice Instant activation (whitelist): a trusted borrower's collateral is active on deposit, so it
    ///         borrows with no maturation wait. Revoking restores the timer for fresh deposits.
    function test_instantActivation_skipsMaturationDelay() public {
        uint256 livePrice = market.oracle.price();
        _setInstantActivation(BORROWER, true);
        assertTrue(market.controller.hasInstantActivation(BORROWER), "borrower whitelisted");

        uint256 col = _dealCol(BORROWER, _collateralForThreshold());
        uint256 borrowAmount = _maxBorrow(market, col, livePrice) / 4;
        uint256 lend = borrowAmount * 2;

        _requireSupplyHeadroom(market, lend);
        _dealLoan(LENDER, lend);

        vm.prank(LENDER);
        market.core.supply(market.params, lend, 0, LENDER, "");
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, col, BORROWER, "");

        // No warp: the deposit is active immediately, so the borrow goes through.
        _assertCollateralState(market.controller, BORROWER, col, 0, 0);
        vm.prank(BORROWER);
        market.core.borrow(market.params, borrowAmount, 0, BORROWER, BORROWER);
        assertEq(market.loanToken.balanceOf(BORROWER), borrowAmount, "borrowed with no maturation wait");

        // Revoke restores the timer: a fresh deposit enters activation instead of going straight to active.
        _setInstantActivation(BORROWER, false);
        uint256 more = _dealCol(BORROWER, _collateralForThreshold());
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, more, BORROWER, "");
        _assertCollateralState(market.controller, BORROWER, col, more, 0);
    }

    /// @notice Open-debt collateral floor: while a borrower owes debt, a withdrawal may not draw active
    ///         collateral below the activation threshold (`minActivationAmount`) — sub-threshold active
    ///         collateral has zero borrow capacity, so the open debt fails the health gate. Repaying to zero
    ///         lifts the constraint. Amounts derive from the LIVE threshold.
    function test_withdraw_collateralFloorWithOpenDebt() public {
        uint256 livePrice = market.oracle.price();
        uint256 min = uint256(_activationConfig(market).minActivationAmount);
        uint256 aboveFloor = min + C; // the smallest lot the floor still permits with open debt

        uint256 col = _dealCol(BORROWER, _collateralForThreshold()); // comfortably above the threshold
        assertGt(col, aboveFloor + C, "collateral above the threshold for the test");

        // The debt has to survive the withdrawal down to `aboveFloor`, so size it against what THAT much
        // collateral can carry, not against the starting position.
        uint256 borrowAmount = _maxBorrow(market, aboveFloor, livePrice) / 8;
        uint256 lend = borrowAmount * 2;

        _requireSupplyHeadroom(market, lend);
        _dealLoan(LENDER, lend);

        vm.prank(LENDER);
        market.core.supply(market.params, lend, 0, LENDER, "");
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, col, BORROWER, "");
        _warpPastActivation();

        vm.prank(BORROWER);
        market.core.borrow(market.params, borrowAmount, 0, BORROWER, BORROWER);

        // Down to just above the threshold is allowed (health is loose, so the threshold is what binds).
        vm.prank(BORROWER);
        market.core.withdrawCollateral(market.params, col - aboveFloor, BORROWER, BORROWER);

        // The next 2 C would drop active collateral below the threshold with open debt: zero capacity, reverts.
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        market.core.withdrawCollateral(market.params, 2 * C, BORROWER, BORROWER);

        // Repay the debt to zero, then the floor no longer applies and the rest comes out.
        _dealLoan(BORROWER, borrowAmount * 2); // headroom over the borrow for accrued interest
        uint128 borrowShares = market.core.position(market.id, BORROWER).borrowShares;
        vm.prank(BORROWER);
        market.core.repay(market.params, 0, borrowShares, BORROWER, "");
        vm.prank(BORROWER);
        market.core.withdrawCollateral(market.params, aboveFloor, BORROWER, BORROWER);
    }

    /// @notice Collateral floor on borrow: a position whose active collateral is below the activation threshold
    ///         cannot open debt — its borrow capacity is zero. Symmetric to the withdraw case, but binds before
    ///         any debt exists.
    function test_borrow_belowPositionFloorReverts() public {
        uint256 livePrice = market.oracle.price();
        uint256 belowFloor = uint256(_activationConfig(market).minActivationAmount) / 2; // half the threshold:
        // sub-threshold

        uint256 col = _dealCol(BORROWER, _collateralForThreshold()); // above the threshold
        assertGt(col, belowFloor + 2 * C, "collateral above the threshold for the test");

        // Enough supply that the borrow below fails on capacity, not on market liquidity.
        uint256 lend = _maxBorrow(market, col, livePrice) / 4;
        _requireSupplyHeadroom(market, lend);
        _dealLoan(LENDER, lend);

        vm.prank(LENDER);
        market.core.supply(market.params, lend, 0, LENDER, "");
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, col, BORROWER, "");
        _warpPastActivation();

        // No debt yet, so the withdraw health gate does not bind: draw active collateral below the threshold.
        vm.prank(BORROWER);
        market.core.withdrawCollateral(market.params, col - belowFloor, BORROWER, BORROWER);
        _assertCollateralState(market.controller, BORROWER, belowFloor, 0, 0); // active collateral below the threshold

        // Sub-threshold active collateral has zero borrow capacity, so the borrow reverts. (Draw above the
        // dust-market floor: a 1-wei borrow would trip that floor first, before reaching the capacity gate.)
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        market.core.borrow(market.params, L, 0, BORROWER, BORROWER);
    }

    /// @dev Happy-path settle: with two active borrowers, cutting the allowed slice against the queue root seizes
    ///      collateral at the oracle price and pays the lender the collateral token. The root borrower's debt is sized
    /// near the LLTV ceiling so it is the queue root over the second borrower and the over-collateralized
    ///      liquidity-pin borrower.
    function test_settle_happyPath() public {
        uint256 livePrice = market.oracle.price();

        uint256 borrowerCollateral = _dealCol(BORROWER, 20 * C);
        uint256 secondBorrowerCollateral = _dealCol(SECOND_BORROWER, 20 * C);

        uint256 borrowerDebt = _maxBorrow(market, borrowerCollateral, livePrice) * 85 / 100; // near-LLTV: queue root
        uint256 secondBorrowerDebt = _maxBorrow(market, secondBorrowerCollateral, livePrice) * 20 / 100; // low LTV:
        // tail

        uint256 lend = borrowerDebt + secondBorrowerDebt + 2 * L;
        _requireSupplyHeadroom(market, lend);
        _dealLoan(LENDER, lend);
        vm.prank(LENDER);
        market.core.supply(market.params, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, borrowerCollateral, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        market.core.supplyCollateral(market.params, secondBorrowerCollateral, SECOND_BORROWER, "");

        _warpPastActivation();

        assertTrue(borrowerDebt < _maxBorrow(market, borrowerCollateral, livePrice), "borrower debt under LLTV");
        assertTrue(
            secondBorrowerDebt < _maxBorrow(market, secondBorrowerCollateral, livePrice), "second debt under LLTV"
        );

        vm.prank(BORROWER);
        market.core.borrow(market.params, borrowerDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        market.core.borrow(market.params, secondBorrowerDebt, 0, SECOND_BORROWER, SECOND_BORROWER);

        _assertCollateralState(market.controller, BORROWER, borrowerCollateral, 0, 0);
        _assertCollateralState(market.controller, SECOND_BORROWER, secondBorrowerCollateral, 0, 0);

        // Accrued interest moves the borrow-share rate off 1e6, where up- and down-rounded debt differ.
        uint256 postedPrice = market.oracle.price();
        vm.warp(block.timestamp + 7 days);
        _setOraclePrice(postedPrice); // the source publishes its price again
        _accrueInterest();

        // Drain free liquidity to zero so the lender's cut must go through settle, then require the test borrower
        // is the queue root — a pre-existing riskier borrower would otherwise take the slice.
        _setFreeLiquidity(0);
        (address root,) = market.controller.nextSettlementBorrower(0);
        require(root == BORROWER, "settle_happyPath: a pre-existing riskier borrower outranks the test borrower");

        _settleAndAssert(livePrice, borrowerCollateral);
    }

    /// @notice One scenario exercising the heap-driven settle ordering end-to-end.
    /// @dev Covers, in order:
    ///        - three borrowers at different risk levels; queue root tracks the highest-LTV one;
    ///        - a cut targeting the root reduces it but does not flip the order;
    ///        - the root opts another borrower in via a settlement LTV, so a non-root cut succeeds;
    ///        - the lowest-LTV borrower is never touched throughout the scenario.
    function test_settle_heapPicksTopBorrower() public {
        uint256 livePrice = market.oracle.price();

        uint256 countBefore = market.controller.settlementBorrowersCount();

        uint256 highCol = _dealCol(BORROWER, 20 * C);
        uint256 midCol = _dealCol(SECOND_BORROWER, 20 * C);
        uint256 lowCol = _dealCol(THIRD_BORROWER, 20 * C);

        uint256 highDebt = _maxBorrow(market, highCol, livePrice) * 85 / 100; // near-LLTV: queue root
        uint256 midDebt = _maxBorrow(market, midCol, livePrice) * 45 / 100;
        uint256 lowDebt = _maxBorrow(market, lowCol, livePrice) * 15 / 100;

        // Lender saturates the market so every cut below has to go through settle and not the ordinary withdraw path.
        uint256 lend = highDebt + midDebt + lowDebt + 2 * L;
        _requireSupplyHeadroom(market, lend);
        _dealLoan(LENDER, lend);
        vm.prank(LENDER);
        market.core.supply(market.params, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, highCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        market.core.supplyCollateral(market.params, midCol, SECOND_BORROWER, "");
        vm.prank(THIRD_BORROWER);
        market.core.supplyCollateral(market.params, lowCol, THIRD_BORROWER, "");

        _warpPastActivation();

        vm.prank(BORROWER);
        market.core.borrow(market.params, highDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        market.core.borrow(market.params, midDebt, 0, SECOND_BORROWER, SECOND_BORROWER);
        vm.prank(THIRD_BORROWER);
        market.core.borrow(market.params, lowDebt, 0, THIRD_BORROWER, THIRD_BORROWER);

        // (1) Initial queue order: the three test borrowers are all tracked and the highest-LTV one is at the root.
        assertEq(market.controller.settlementBorrowersCount(), countBefore + 3, "all three active borrowers tracked");
        (address root,) = market.controller.nextSettlementBorrower(0);
        assertEq(root, BORROWER, "highest-LTV borrower at root");

        // Saturate to zero free liquidity so the cuts below settle (adds an over-collateralized pin borrower that
        // ranks below the near-LLTV root, leaving the queue order intact).
        _setFreeLiquidity(0);
        (root,) = market.controller.nextSettlementBorrower(0);
        require(root == BORROWER, "settle_heap: pin disturbed the queue root");

        // (2) A partial cut on the root, half the allowed slice. Cutting half reduces the root's key without
        //     flipping it below the runner-up.
        uint256 cutShares = _rootCutShares() / 2;
        vm.prank(LENDER);
        market.core.settle(market.params, cutShares, LENDER, BORROWER, LENDER);
        (root,) = market.controller.nextSettlementBorrower(0);
        assertEq(root, BORROWER, "BORROWER still highest after first partial cut");

        // (3) Targeting the second borrower while it isn't the queue root is rejected by the controller hook:
        //     a non-root borrower without a personal settlement LTV has a zero slice, so any cut exceeds it.
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSignature("SettlementExceedsAllowed()"));
        market.core.settle(market.params, cutShares, LENDER, SECOND_BORROWER, LENDER);

        // (4) SECOND_BORROWER opts in to a 5% post-cut LTV — they are now eligible regardless of
        //     queue position: a cut within their personal slice succeeds against them.
        vm.prank(SECOND_BORROWER);
        market.controller.setSettlementLtv(0.05e18);
        cutShares = _personalCutShares(SECOND_BORROWER);
        vm.prank(LENDER);
        market.core.settle(market.params, cutShares, LENDER, SECOND_BORROWER, LENDER);

        // (5) THIRD_BORROWER (lowest LTV, no settlement LTV) is never touched throughout the scenario.
        Position memory _pLow = market.core.position(market.id, THIRD_BORROWER);
        (uint128 lowBorrowSharesAfter, uint128 lowCollateralAfter) = (_pLow.borrowShares, _pLow.collateral);
        assertEq(uint256(lowCollateralAfter), lowCol, "low-LTV borrower's collateral untouched");
        assertGt(lowBorrowSharesAfter, 0, "low-LTV borrower still has debt");
    }

    /// @notice Settle of the queue root is blocked while it is bad debt, and succeeds again once it is solvent.
    /// @dev Setup: a high-LTV root (BORROWER) and a healthy tail (SECOND_BORROWER). A price fall — sized
    ///      RELATIVE to the root's own debt / collateral so it lands underwater at any live price — pushes the root
    ///      insolvent (debt > collateral value).
    function testRevert_settle_whenHeapRootBadDebt() public {
        uint256 livePrice = market.oracle.price();

        uint256 headCol = _dealCol(BORROWER, 25 * C);
        uint256 tailCol = _dealCol(SECOND_BORROWER, 25 * C);

        uint256 headDebt = _maxBorrow(market, headCol, livePrice) * 85 / 100; // near the LLTV ceiling: queue root
        uint256 tailDebt = _maxBorrow(market, tailCol, livePrice) * 10 / 100; // healthy tail

        uint256 lend = headDebt + tailDebt + 2 * L;
        _requireSupplyHeadroom(market, lend);
        _dealLoan(LENDER, lend);
        vm.prank(LENDER);
        market.core.supply(market.params, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, headCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        market.core.supplyCollateral(market.params, tailCol, SECOND_BORROWER, "");

        _warpPastActivation();

        vm.prank(BORROWER);
        market.core.borrow(market.params, headDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        market.core.borrow(market.params, tailDebt, 0, SECOND_BORROWER, SECOND_BORROWER);

        // Precondition at the LIVE rate: the test borrower heads the queue and nobody is bad debt yet.
        (address root,) = market.controller.nextSettlementBorrower(0);
        assertEq(root, BORROWER, "high-LTV borrower is the queue head");
        require(
            !market.controller.hasBadDebt(), "settle_badDebt: a pre-existing borrower is already bad debt at live rate"
        );

        // Drain free liquidity to zero (at the live rate) so the successful settle below reaches collateral.
        _setFreeLiquidity(0);

        // Cut sized to the allowed slice at the real rate (reused after the rebase is cleared).
        uint256 cut = _rootCutShares() / 2;

        // A price fall RELATIVE to the head's position: the head's collateral is worth ~10% less than its debt (bad
        // debt) regardless of the live price. The tail stays healthy.
        uint256 headDebtAssets = market.controller.positionOf(BORROWER).debtAssets;
        uint256 headRawCollateral = market.core.position(market.id, BORROWER).collateral;
        uint256 oldPrice = market.oracle.price();
        _setOraclePrice(Math.mulDiv(headDebtAssets, ORACLE_PRICE_SCALE, headRawCollateral) * 9 / 10);
        assertTrue(market.controller.hasBadDebt(), "head is bad debt after the fall");

        // Targeting the head is blocked while the head is bad debt: the controller's bad-debt guard fires.
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSignature("SettlementBadDebt()"));
        market.core.settle(market.params, cut, LENDER, BORROWER, LENDER);

        // Restore the price; the head is solvent again; the same cut against the head now succeeds.
        _setOraclePrice(oldPrice);
        assertFalse(market.controller.hasBadDebt(), "head solvent after restore");
        (root,) = market.controller.nextSettlementBorrower(0);
        require(root == BORROWER, "settle_badDebt: root drifted off the test borrower after restore");
        vm.prank(LENDER);
        market.core.settle(market.params, cut, LENDER, BORROWER, LENDER);
    }

    /// @notice Settle works on an unhealthy-but-solvent position (LLTV < LTV < 100%).
    /// @dev Soft-liquidation must reach risky positions, not just healthy ones. A price fall — sized RELATIVE
    ///      to the borrower's own position so it lands at a post-fall LTV inside (LLTV, 1) at any live price AND
    ///      any live LLTV — pushes the borrower above LLTV (unhealthy) while keeping their collateral worth more
    ///      than their debt (solvent).
    function test_settle_worksOnUnhealthyButSolventPosition() public {
        uint256 livePrice = market.oracle.price();

        uint256 col = _dealCol(BORROWER, 25 * C);
        uint256 borrowAmount = _maxBorrow(market, col, livePrice) * 85 / 100; // near-LLTV, healthy at the live rate

        uint256 lend = borrowAmount + 2 * L;
        _requireSupplyHeadroom(market, lend);
        _dealLoan(LENDER, lend);
        vm.prank(LENDER);
        market.core.supply(market.params, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, col, BORROWER, "");
        _warpPastActivation();
        vm.prank(BORROWER);
        market.core.borrow(market.params, borrowAmount, 0, BORROWER, BORROWER);

        (address root,) = market.controller.nextSettlementBorrower(0);
        require(root == BORROWER, "settle_unhealthy: a pre-existing riskier borrower outranks the test borrower");
        _setFreeLiquidity(0);

        // A price fall RELATIVE to the position: land BORROWER halfway between the live LLTV and 100% — above
        // LLTV (unhealthy), below 100% (solvent) — whatever the live price AND whatever the market's LLTV. Derived,
        // not fixed: a hardcoded 90% is only unhealthy on a market whose LLTV is below it.
        // `price = debt / (collateral * targetLtv)`.
        uint256 debtAssets = market.controller.positionOf(BORROWER).debtAssets;
        uint256 rc = market.core.position(market.id, BORROWER).collateral;
        uint256 targetLtv = market.params.lltv + (WAD - market.params.lltv) / 2;
        uint256 droppedPrice = _setOraclePrice(Math.mulDiv(debtAssets, WAD * ORACLE_PRICE_SCALE, rc * targetLtv));

        assertLt(droppedPrice, livePrice, "the price falls");
        assertGt(debtAssets, _maxBorrow(market, rc, droppedPrice), "position is unhealthy (LTV > LLTV)");
        assertGt(Math.mulDiv(rc, droppedPrice, ORACLE_PRICE_SCALE), debtAssets, "position is solvent (value > debt)");
        assertFalse(market.controller.hasBadDebt(), "head is not bad debt");

        // The cut succeeds even though the borrower is unhealthy. Slice sized from the mocked-price policy slice.
        _settleUnhealthyAndAssert(_rootCutShares() / 2, droppedPrice, rc);
    }

    /// @notice setSettlementLtv stores the borrower's target LTV; rejects ltv >= 1e18.
    function test_setSettlementLtv_storesAndRejectsOutOfRange() public {
        (uint256 wm0,) = market.controller.settlementLtv(BORROWER);
        assertEq(wm0, 0, "default unset");

        vm.prank(BORROWER);
        market.controller.setSettlementLtv(0.6e18);
        (uint256 wm1,) = market.controller.settlementLtv(BORROWER);
        assertEq(wm1, 0.6e18, "stored");

        // Clear with 0.
        vm.prank(BORROWER);
        market.controller.setSettlementLtv(0);
        (uint256 wm2,) = market.controller.settlementLtv(BORROWER);
        assertEq(wm2, 0, "cleared");

        // Out-of-range rejected.
        vm.prank(BORROWER);
        vm.expectRevert(abi.encodeWithSignature("SettlementLtvOutOfRange()"));
        market.controller.setSettlementLtv(1e18);
    }

    /// @notice When the queue root has a settlement LTV, the root's allowed slice is bumped up to bring
    ///         the borrower's LTV down to it. Close runner-up key keeps the algorithmic
    ///         slice small so the settlement-LTV slice dominates.
    function test_settlementLtv_bumpsHeapSlice() public {
        uint256 livePrice = market.oracle.price();

        // Collateral sized so the post-cut remainder stays above the activation minimum, keeping the
        // settlement-LTV slice off the dust-extension clamp (which would promote it to the full debt).
        uint256 hotCol = _dealCol(BORROWER, 30 * C);
        uint256 coldCol = _dealCol(SECOND_BORROWER, 30 * C);

        // Close LTVs -> small key gap -> small algorithmic slice; BORROWER a hair higher so it heads the queue.
        uint256 hotDebt = _maxBorrow(market, hotCol, livePrice) * 75 / 100;
        uint256 coldDebt = _maxBorrow(market, coldCol, livePrice) * 71 / 100;

        uint256 lend = hotDebt + coldDebt + 2 * L;
        _requireSupplyHeadroom(market, lend);
        _dealLoan(LENDER, lend);
        vm.prank(LENDER);
        market.core.supply(market.params, lend, 0, LENDER, "");

        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, hotCol, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        market.core.supplyCollateral(market.params, coldCol, SECOND_BORROWER, "");

        _warpPastActivation();
        vm.prank(BORROWER);
        market.core.borrow(market.params, hotDebt, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        market.core.borrow(market.params, coldDebt, 0, SECOND_BORROWER, SECOND_BORROWER);

        (address rootBefore,) = market.controller.nextSettlementBorrower(0);
        require(rootBefore == BORROWER, "settlementLtv_bump: a pre-existing riskier borrower heads the queue");
        uint256 sliceBefore = _dashboardSliceAssets(market.controller, rootBefore);

        // BORROWER opts in to a 30% post-cut LTV — a deep target.
        vm.prank(BORROWER);
        market.controller.setSettlementLtv(0.3e18);

        (address rootAfter,) = market.controller.nextSettlementBorrower(0);
        uint256 sliceAfter = _dashboardSliceAssets(market.controller, rootAfter);
        assertEq(rootAfter, BORROWER, "root unchanged");
        assertGt(sliceAfter, sliceBefore, "settlement LTV raised the slice");

        // Settlement-LTV slice closed form: c = (D*WAD - W*V) / (WAD - W), with V = col * price / 1e36, recomputed
        // from the live position and price.
        uint256 debt = market.controller.positionOf(BORROWER).debtAssets;
        uint256 colValue = Math.mulDiv(hotCol, livePrice, ORACLE_PRICE_SCALE);
        uint256 expected = (debt * WAD - 0.3e18 * colValue) / (WAD - 0.3e18);
        assertApproxEqAbs(sliceAfter, expected, L / 1000, "slice matches settlement-LTV formula");
    }

    /// @notice Direct EOA-lender can settle a non-root borrower iff that borrower has a personal
    ///         settlement LTV set. Without one its policy slice is zero, so the controller hook reverts
    ///         `SettlementExceedsAllowed` on any cut.
    function test_settle_eligibleViaPersonalSettlementLtv() public {
        uint256 livePrice = market.oracle.price();

        _requireSupplyHeadroom(market, 10 * L);
        _dealLoan(LENDER, 10 * L);
        vm.prank(LENDER);
        market.core.supply(market.params, 10 * L, 0, LENDER, "");

        // Two borrowers, BORROWER higher LTV than SECOND_BORROWER. Total borrow drains the supply so the lender's
        // exit must trigger settle.
        uint256 col1 = _dealCol(BORROWER, 20 * C);
        uint256 col2 = _dealCol(SECOND_BORROWER, 20 * C);
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, col1, BORROWER, "");
        vm.prank(SECOND_BORROWER);
        market.core.supplyCollateral(market.params, col2, SECOND_BORROWER, "");

        _warpPastActivation();
        vm.prank(BORROWER);
        market.core.borrow(market.params, 7 * L, 0, BORROWER, BORROWER);
        vm.prank(SECOND_BORROWER);
        market.core.borrow(market.params, 3 * L, 0, SECOND_BORROWER, SECOND_BORROWER);

        // Accrued interest moves the borrow-share rate off 1e6, where up- and down-rounded debt differ.
        uint256 postedPrice = market.oracle.price();
        vm.warp(block.timestamp + 7 days);
        _setOraclePrice(postedPrice); // the source publishes its price again
        _accrueInterest();

        _setFreeLiquidity(0);

        // The mechanism only needs SECOND_BORROWER NOT to be the queue root: as a non-root borrower its policy slice
        // is zero, so eligibility must come from its personal settlement LTV, not from heading the queue.
        (address root,) = market.controller.nextSettlementBorrower(0);
        require(root != SECOND_BORROWER, "settle_personalLtv: tail borrower unexpectedly heads the queue");

        // The cut is denominated in the TARGET'S DEBT SHARES — `settle`'s second argument is `borrowShares`, not
        // the settler's supply shares. Sizing it off the lender's supply only lands in range by coincidence of
        // the two share scales, and drifts apart as soon as interest accrues on either side.
        uint256 tailDebtShares = market.core.position(market.id, SECOND_BORROWER).borrowShares;
        uint256 cut = tailDebtShares / 5;

        // Targeting tail SECOND_BORROWER without a settlement LTV -> zero slice -> hook revert.
        vm.prank(LENDER);
        vm.expectRevert(abi.encodeWithSignature("SettlementExceedsAllowed()"));
        market.core.settle(market.params, cut, LENDER, SECOND_BORROWER, LENDER);

        // SECOND_BORROWER opts in to 5% post-cut LTV — slice is large enough for the cut.
        vm.prank(SECOND_BORROWER);
        market.controller.setSettlementLtv(0.05e18);

        (uint256 expectedDebt, uint256 expectedCollateral) = _expectedSettlementAmounts(cut, livePrice);
        uint128 colBefore = market.core.position(market.id, SECOND_BORROWER).collateral;

        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            market.core.settle(market.params, cut, LENDER, SECOND_BORROWER, LENDER);

        assertEq(
            market.core.position(market.id, SECOND_BORROWER).borrowShares,
            tailDebtShares - cut,
            "exactly the requested debt shares were cancelled"
        );
        assertEq(debtCanceled, expectedDebt, "debt canceled is the up-rounded value of the requested shares");
        assertEq(
            uint256(market.core.position(market.id, SECOND_BORROWER).collateral),
            uint256(colBefore) - collateralSeized,
            "tail collateral debited"
        );
        assertEq(collateralSeized, expectedCollateral, "collateral uses the down-rounded borrow-share value");
    }

    /// @notice A banned borrower's collateral never settles into `active`, and its borrow is hard-blocked.
    ///         Exercises the guardian-ban path: a ban skips maturation (like a freeze) and hard-blocks the borrow.
    ///         Runs through the REAL guardian committee read from the deployed registry.
    function test_ban_bannedCollateralNeverMaturesAndBorrowBlocked() public {
        _requireSupplyHeadroom(market, 10 * L);
        _dealLoan(LENDER, 10 * L);
        vm.prank(LENDER);
        market.core.supply(market.params, 10 * L, 0, LENDER, "");

        uint256 col = _dealCol(BORROWER, 20 * C);
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, col, BORROWER, "");
        _assertCollateralState(market.controller, BORROWER, 0, col, 0);

        // Ban BORROWER through the REAL committee. The loop over the live guardian set lives in a helper, not
        // here: how many guardians a quorum takes is a property of the deployment, not of the behaviour this
        // test names, and a failure inside it should point at the committee rather than at this test.
        _banViaLiveCommittee(market.id, BORROWER);

        // Warp far past any normal activation delay — a banned address never settles.
        uint256 postedPrice = market.oracle.price();
        vm.warp(block.timestamp + 30 days);
        _setOraclePrice(postedPrice); // the source publishes its price again
        ILidoLendMarketController.BorrowerPosition memory pv = market.controller.positionOf(BORROWER);
        assertTrue(pv.banned, "banned");

        // `positionOf` reads stored buckets, so drive a sync the ban does not gate: a top-up syncs before it books.
        // Had the first lot matured, `activating` would hold the top-up alone.
        uint256 more = _dealCol(BORROWER, 20 * C);
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, more, BORROWER, "");
        _assertCollateralState(market.controller, BORROWER, 0, col + more, 0); // still activating, never active

        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        market.core.borrow(market.params, L, 0, BORROWER, BORROWER);
    }

    /// @notice The activation delay is inflow-scaled (a larger inflow adds more to the throttle and
    ///         earns a longer delay) and is enforced (collateral does not settle before its unlock).
    /// @dev Reworked to be state-robust: instead of assuming a near-empty market, it reads the controller's own
    ///      delay predictor for each lot BEFORE supplying and asserts each lot's unlock lands exactly on
    ///      `supplyTs + predictedDelay`. A loud precondition rejects an already-saturated inflow (which would
    ///      collapse both predictions to the delay cap and make the comparison vacuous).
    function test_maturation_delayScalesWithInflowAndIsEnforced() public {
        uint256 smallCol = uint256(_activationConfig(market).minActivationAmount) * 5 / 2; // clears the dust floor
        uint256 bigCol = smallCol * 32; // a much larger inflow, still well under `maxDelayInflow`

        // Predict each lot's delay from the controller: the small lot at the current inflow, the big lot at the
        // inflow the small lot leaves behind (same block, no decay, so the increment folds into the sum).
        uint256 dSmall = market.controller.currentActivationDelay(smallCol);
        uint256 dBig = market.controller.currentActivationDelay(smallCol + bigCol);
        require(
            dSmall < uint256(_activationConfig(market).maxActivationDelay),
            "maturation: inflow throttle already saturated"
        );

        uint256 ts = block.timestamp;
        _dealCol(BORROWER, smallCol);
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, smallCol, BORROWER, "");
        uint256 smallUnlock = market.controller.positionOf(BORROWER).unlockTime;

        _dealCol(SECOND_BORROWER, bigCol);
        vm.prank(SECOND_BORROWER);
        market.core.supplyCollateral(market.params, bigCol, SECOND_BORROWER, "");
        uint256 bigUnlock = market.controller.positionOf(SECOND_BORROWER).unlockTime;

        // Each lot's unlock is exactly its supply time plus the predicted, inflow-scaled delay (same block).
        assertEq(smallUnlock, ts + dSmall, "small lot unlock == supply ts + predicted delay");
        assertEq(bigUnlock, ts + dBig, "big lot unlock == supply ts + predicted delay");
        // The bigger inflow piled more onto the inflow accumulator -> strictly longer delay.
        assertGt(bigUnlock, smallUnlock, "bigger inflow -> longer activation delay");
        // The small lot activated (not dust) and matures under the delay cap.
        assertGt(smallUnlock, ts, "small deposit activated (not dust)");

        // Enforced: while the timer runs the lot is held in `activating`, never borrowable as `active`.
        _assertCollateralState(market.controller, BORROWER, 0, smallCol, 0);
    }

    /// @notice A same-tx supplyCollateral -> withdrawCollateral round-trip is inflow-neutral: the deposit's
    ///         inflow addition is reversed on the same-tx withdrawal, so a flash loan cannot pump the inflow.
    function test_flashUndo_sameTxRoundTripIsInflowNeutral() public {
        // Seed real inflow with a committed deposit so `currentInflow()` is observably non-zero.
        uint256 seed = _dealCol(BORROWER, uint256(_activationConfig(market).minActivationAmount) * 5 / 2);
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, seed, BORROWER, "");
        uint256 inflowBefore = market.controller.currentInflow();
        assertGt(inflowBefore, 0, "seed deposit added to inflow");

        // Flash actor supplies and withdraws the same collateral in ONE transaction.
        FlashRoundTrip flasher = new FlashRoundTrip();
        uint256 amount = _dealCol(address(flasher), uint256(_activationConfig(market).minActivationAmount) * 4);
        flasher.run(market.core, market.params, amount);

        // No time passed, so no decay: the round-trip must leave the inflow exactly where it was.
        assertEq(market.controller.currentInflow(), inflowBefore, "same-tx round-trip is inflow-neutral");
    }

    // ---
    // HELPERS
    // ---

    function _settleAndAssert(uint256 price, uint256 borrowerCollateral) internal {
        uint256 sharesToExit = _rootCutShares();
        (uint256 expectedDebt, uint256 expectedCollateral) = _expectedSettlementAmounts(sharesToExit, price);

        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            market.core.settle(market.params, sharesToExit, LENDER, BORROWER, LENDER);

        assertEq(debtCanceled, expectedDebt, "debt uses the up-rounded borrow-share value");
        assertEq(collateralSeized, expectedCollateral, "collateral uses the down-rounded borrow-share value");
        assertGt(debtCanceled, 0, "settled the allowed slice");
        assertEq(market.collateralToken.balanceOf(LENDER), collateralSeized, "lender received the collateral");

        _assertBorrowerCollateralDebited(borrowerCollateral, collateralSeized);
    }

    /// @dev Borrow-share cut allowed for the current queue root.
    function _rootCutShares() internal view returns (uint256) {
        (, SettlementSlice memory slice) = market.controller.nextSettlementBorrower(0);
        return slice.borrowShares;
    }

    /// @dev Half of `borrower`'s personal settlement slice in borrow shares; the borrower must have opted in.
    function _personalCutShares(address borrower) internal view returns (uint256) {
        uint256 personalSliceAssets = market.controller.positionOf(borrower).personalSliceAssets;
        require(personalSliceAssets != 0, "settle_heap: borrower has no personal slice");
        MarketState memory market_ = market.core.market(market.id);
        return SharesMathLib.toSharesUp(personalSliceAssets, market_.totalBorrowAssets, market_.totalBorrowShares) / 2;
    }

    function _expectedSettlementAmounts(uint256 borrowShares, uint256 price)
        internal
        view
        returns (uint256 debt, uint256 collateral)
    {
        MarketState memory market_ = market.core.market(market.id);
        debt = SharesMathLib.toAssetsUp(borrowShares, market_.totalBorrowAssets, market_.totalBorrowShares);
        collateral = Math.mulDiv(
            SharesMathLib.toAssetsDown(borrowShares, market_.totalBorrowAssets, market_.totalBorrowShares),
            ORACLE_PRICE_SCALE,
            price
        );
    }

    function _settleUnhealthyAndAssert(uint256 borrowShares, uint256 price, uint256 collateralBefore) internal {
        (uint256 expectedDebt, uint256 expectedCollateral) = _expectedSettlementAmounts(borrowShares, price);
        vm.prank(LENDER);
        (uint256 collateralSeized, uint256 debtCanceled,,) =
            market.core.settle(market.params, borrowShares, LENDER, BORROWER, LENDER);

        assertEq(debtCanceled, expectedDebt, "debt uses the up-rounded borrow-share value");
        assertEq(collateralSeized, expectedCollateral, "collateral uses the down-rounded borrow-share value");
        assertEq(
            market.core.position(market.id, BORROWER).collateral,
            collateralBefore - collateralSeized,
            "borrower collateral debited"
        );
    }

    function _dashboardSliceAssets(ILidoLendMarketController controller, address borrower)
        internal
        view
        returns (uint256)
    {
        ILidoLendMarketController.BorrowerPosition memory dashboard = controller.positionOf(borrower);
        return dashboard.personalSliceAssets > dashboard.queueRootSliceAssets
            ? dashboard.personalSliceAssets
            : dashboard.queueRootSliceAssets;
    }

    /// @dev Collateral that comfortably clears the LIVE activation threshold, twice it, tracking governance moving the
    ///      threshold.
    function _collateralForThreshold() internal view returns (uint256) {
        return 2 * uint256(_activationConfig(market).minActivationAmount);
    }

    function _assertBorrowerCollateralDebited(uint256 initialCollateral, uint256 collateralSeized) internal view {
        uint128 borrowerRawCollateral = market.core.position(market.id, BORROWER).collateral;
        assertEq(uint256(borrowerRawCollateral), initialCollateral - collateralSeized, "raw collateral debited");
        _assertCollateralState(market.controller, BORROWER, initialCollateral - collateralSeized, 0, 0);
    }

    /// @dev Gives `user` `amount` more loan token and approves the core for it.
    function _dealLoan(address user, uint256 amount) internal {
        deal(address(market.loanToken), user, market.loanToken.balanceOf(user) + amount);
        _approve(address(market.loanToken), user, address(market.core), type(uint256).max);
    }

    /// @dev Gives `user` `amount` more collateral and approves the core. Exact, so a lot can be sized precisely
    ///      against the LIVE dust floor / inflow accumulator.
    function _dealCol(address user, uint256 amount) internal returns (uint256) {
        collateralIssuer.dealCollateral(user, amount);
        _approve(address(market.collateralToken), user, address(market.core), type(uint256).max);
        return amount;
    }

    /// @dev Latch a ban on `account` through the live guardian committee: a quorum of distinct guardians each
    ///      flag it. The test contract is not a guardian on the deployed registry, so each flag is pranked as the
    ///      real guardian. Asserts the ban actually latched, so a committee whose quorum moved fails here with a
    ///      message about the committee rather than further downstream.
    function _banViaLiveCommittee(Id id, address account) internal {
        (address[] memory guardians,) = market.guardianSignals.getGuardians();
        uint256 quorum = market.guardianSignals.getQuorum();
        require(guardians.length >= quorum, "ban: live guardian set smaller than its quorum");

        address[] memory toFlag = new address[](1);
        toFlag[0] = account;
        for (uint256 i; i < quorum; ++i) {
            vm.prank(guardians[i]);
            market.guardianSignals.flag(id, guardians[i], toFlag);
        }

        require(market.guardianSignals.isBanned(id, account), "ban: quorum of flags did not latch a ban");
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
