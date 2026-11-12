// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {SettlementQueueLib} from "../../src/libs/SettlementQueueLib.sol";
import {SettlementSlice} from "../../src/types/SettlementTypes.sol";
import {Id, Market as MorphoMarket, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {CallbackERC20, ITokenTransferHook, MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @dev Vault lender that redeems vault shares from inside the collateral transfer of its own settle.
contract ReentrantRedeemer is ITokenTransferHook {
    ILidoLendERC4626 private immutable VAULT;
    /// @dev Vault shares to redeem in the callback. Zero means the callback does nothing.
    uint256 public redeemShares;
    uint256 public reentrantPayout;
    bool public reentered;

    constructor(ILidoLendERC4626 vault) {
        VAULT = vault;
    }

    function arm(uint256 shares) external {
        redeemShares = shares;
    }

    function onTokenTransfer(address, uint256) external {
        if (redeemShares == 0) return;
        reentered = true;
        reentrantPayout = VAULT.redeem(redeemShares, address(this), address(this));
    }
}

/// @notice L2 controller-safety scenarios that the per-method suites left to the integration layer: the
///         settle bad-debt gate (the controller's O(1) root health-check discharging the duty the core skips
///         on settle), the collateral floor on a debt-bearing withdrawal, and the per-borrower settlement
///         LTV opt-in.
contract SettlementSafetyTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev Raw collateral of each tied-key borrower. One rounded risk-key unit then spans 1e7 borrow shares, about
    ///      ten loan units of debt.
    uint256 private constant TIED_COLLATERAL = 1e25;
    uint256 private constant TIED_KEY_SHARES = TIED_COLLATERAL / 1e18;
    /// @dev Ten loan units per collateral unit, so ten consecutive cut values all seize the whole collateral.
    uint256 private constant TIED_PRICE = 10e36;
    uint256 private constant TIED_VALUE = TIED_COLLATERAL * TIED_PRICE / 1e36;
    /// @dev Borrow shares left on the sub-unit root. About 0.1 loan unit of debt at the opening rate of 1e6 shares
    ///      per loan unit, so its debt rounds up to one unit. Its key, 1e23, is above the healthy borrower's key.
    uint256 private constant SUB_UNIT_SHARES = 1e5;
    /// @dev Below `ORACLE_PRICE_SCALE`, so one collateral unit is worth 0.61 loan unit and rounds down to zero.
    uint256 private constant SUB_UNIT_PRICE = 0.61e36;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function _seed(uint256 collat, uint256 borrowBps)
        internal
        returns (address lender, address borrower, uint256 shares)
    {
        Market storage m = _m();
        lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        shares = m.vaultDeposit(lender, 1000 ether);
        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();
        uint256 maxBorrow = collat * oraclePrice / 1e36 * 80 / 100;
        m.borrow(borrower, maxBorrow * borrowBps / 10_000);
    }

    /// @dev The tied-key case of the spec. `root` and `insolvent` post equal collateral and their risk keys round to
    ///      the same value, so `root`, queued first, stays the root. The root's debt equals its collateral value.
    ///      `insolvent` owes more than its collateral value and opts into personal settlement.
    function _seedTiedKeys() private returns (address root, address insolvent) {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 3 * TIED_VALUE);
        m.vaultDeposit(lender, 3 * TIED_VALUE);

        root = _actor("root");
        insolvent = _actor("insolvent");
        _fund(m.collateralToken, root, TIED_COLLATERAL);
        m.supplyCollateral(root, TIED_COLLATERAL);
        _fund(m.collateralToken, insolvent, TIED_COLLATERAL);
        m.supplyCollateral(insolvent, TIED_COLLATERAL);
        m.activateCollateral();

        // Borrow at twice the final price to stay within LLTV. The first borrow prices one asset at 1e6 shares.
        MockPriceOracle(address(m.oracle)).setPrice(2 * TIED_PRICE);
        m.borrowByShares(root, TIED_VALUE * 1e6);
        m.borrowByShares(insolvent, TIED_VALUE * 1e6 + TIED_KEY_SHARES - 1);
        m.setSettlementLtv(insolvent, 1);
        MockPriceOracle(address(m.oracle)).setPrice(TIED_PRICE);

        (address queueRoot,) = m.controller.nextSettlementBorrower(0);
        (, uint256[] memory keys) = m.controller.settlementBorrowers(0, 2);
        assertEq(queueRoot, root, "setup: the first borrower stays root");
        assertEq(keys[0], keys[1], "setup: both risk keys round to the same value");
        assertEq(m.controller.positionOf(root).debtAssets, TIED_VALUE, "setup: root debt equals collateral value");
        assertGt(m.controller.positionOf(insolvent).debtAssets, TIED_VALUE, "setup: the tied borrower is insolvent");
        assertFalse(m.controller.hasBadDebt(), "setup: the solvent root passes the bad-debt gate");
    }

    /// @dev `insolvent` keeps debt on zero collateral, has left the queue, and the gate still sees no bad debt.
    function _assertDebtLeftOnZeroCollateral(address root, address insolvent) private view {
        Market storage m = _m();
        Position memory p = m.core.position(m.id, insolvent);
        assertEq(p.collateral, 0, "settle took all collateral");
        assertGt(p.borrowShares, 0, "settle left debt shares");
        assertGt(m.controller.positionOf(insolvent).debtAssets, 0, "the remaining shares carry debt");
        assertEq(m.controller.settlementBorrowersCount(), 1, "the zero-collateral borrower left the queue");
        (address queueRoot,) = m.controller.nextSettlementBorrower(0);
        assertEq(queueRoot, root, "the solvent root stays");
        assertFalse(m.controller.hasBadDebt(), "the gate does not see the remaining debt");
    }

    // ── Bad debt at the queue root: fallback exit has three distinct outcomes ──

    /// @dev A request the free liquidity covers never enters the settle leg, so the bad-debt gate is never
    ///      consulted and the lender exits normally. The cheapest thing to get wrong here is to assume a
    ///      bad-debt root blocks every fallback exit.
    function test_FallbackExit_BadDebtRoot_LiquidRequestStillExits() public {
        Market storage m = _m();
        (address lender, address borrower,) = _seed(100 ether, 9900);
        m.setSettlementLtv(borrower, 0.5e18);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 2);
        m.accrueInterest();
        assertTrue(m.controller.hasBadDebt(), "setup: root must carry bad debt");

        uint256 liquid = m.controller.maxWithdrawableAssets(address(m.vault));
        uint256 request = m.vault.previewWithdraw(liquid / 2);
        assertLe(m.vault.previewRedeem(request), liquid, "setup: request must fit inside free liquidity");

        (uint256 burned, uint256 loanAssets, uint256 seized, uint256 canceled) =
            m.fallbackExit(lender, request, lender, 0);

        assertEq(burned, request, "whole request served by the liquid leg");
        assertGt(loanAssets, 0, "liquid leg paid out");
        assertEq(seized, 0, "settle leg must not have run");
        assertEq(canceled, 0, "settle leg must not have run");
    }

    /// @dev Past the liquid leg with a small settle budget, the quoted cut is small enough to seize less than
    ///      the remaining collateral, so the controller hook runs and rejects on the bad-debt gate.
    function testRevert_FallbackExit_BadDebtRoot_SmallCutHitsBadDebtGate() public {
        Market storage m = _m();
        (address lender, address borrower, uint256 shares) = _seed(100 ether, 9900);
        m.setSettlementLtv(borrower, 0.5e18);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 2);
        m.accrueInterest();
        assertTrue(m.controller.hasBadDebt(), "setup: root must carry bad debt");

        // Just past what the liquid leg can serve, so the settle budget is a small remainder.
        uint256 liquid = m.controller.maxWithdrawableAssets(address(m.vault));
        uint256 request = m.vault.previewWithdraw(liquid) + shares / 1000;
        assertGt(m.vault.previewRedeem(request), liquid, "setup: request must reach the settle leg");

        vm.prank(lender);
        vm.expectRevert(ILidoLendMarketController.SettlementBadDebt.selector);
        m.vault.fallbackExit(request, lender, lender, 0);

        assertEq(m.vault.balanceOf(lender), shares, "no shares burned: liquid leg rolled back too");
    }

    /// @dev With the whole position requested the quote is a full close, which on an underwater borrower
    ///      seizes more collateral than exists. The core rejects on its own bound before the controller hook
    ///      is ever reached, so the failure is the core's message rather than the bad-debt gate.
    function testRevert_FallbackExit_BadDebtRoot_FullCloseExceedsCollateral() public {
        Market storage m = _m();
        (address lender, address borrower, uint256 shares) = _seed(100 ether, 9900);
        m.setSettlementLtv(borrower, 0.5e18);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 20); // deeply underwater
        m.accrueInterest();
        assertTrue(m.controller.hasBadDebt(), "setup: root must carry bad debt");

        vm.prank(lender);
        vm.expectRevert(bytes("settlement exceeds collateral"));
        m.vault.fallbackExit(shares, lender, lender, 0);

        assertEq(m.vault.balanceOf(lender), shares, "no shares burned");
    }

    /// @dev Clearing the bad debt unblocks the same call. Pins that the gate tracks live root health rather
    ///      than latching once bad debt has ever existed.
    function test_FallbackExit_AfterBadDebtIsLiquidated_Succeeds() public {
        Market storage m = _m();
        (address lender, address borrower, uint256 shares) = _seed(100 ether, 9900);
        m.setSettlementLtv(borrower, 0.5e18);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 2);
        m.accrueInterest();
        assertTrue(m.controller.hasBadDebt(), "setup: root must carry bad debt");

        address keeper = _actor("badDebtKeeper");
        _fund(m.loanToken, keeper, 10_000 ether);
        uint256 seizeAll = m.core.position(m.id, borrower).collateral;
        m.liquidateBadDebt(keeper, borrower, seizeAll, 0);
        assertFalse(m.controller.hasBadDebt(), "bad debt cleared");

        // The queue is empty now, so the settle leg quotes nothing and the liquid leg serves what it can.
        (uint256 burned,, uint256 seized,) = m.fallbackExit(lender, shares, lender, 0);
        assertGt(burned, 0, "lender can exit once the bad debt is cleared");
        assertEq(seized, 0, "no settlement needed: the queue is empty");
    }

    /// @dev The settle hook reverts if the queue ROOT (riskiest position) carries bad debt — the controller
    ///      doing the health check the core omits on settle. A hard crash makes the sole borrower's root
    ///      position underwater, so any settle against the market is rejected.
    function testRevert_settle_whenRootIsBadDebt() public {
        Market storage m = _m();
        (address lender, address borrower, uint256 shares) = _seed(100 ether, 9900); // ~99% of LLTV-max

        vm.prank(borrower);
        m.controller.setSettlementLtv(0.5e18); // targeted settlement must have a positive personal slice

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 2); // collateral value now below the debt
        m.accrueInterest();

        address[] memory bs = new address[](1);
        bs[0] = borrower;
        vm.prank(lender);
        vm.expectRevert(ILidoLendMarketController.SettlementBadDebt.selector);
        m.vault.settle(shares / 100, bs, lender, lender);
    }

    // ── Tied risk keys: the root check misses an insolvent non-root borrower ──

    /// @dev A personal direct settle takes all collateral of an insolvent non-root borrower
    ///      and leaves debt that no queue entry or gate tracks.
    function test_tiedKeyPersonalCoreSettle_leavesDebtOnZeroCollateral() public {
        Market storage m = _m();
        (address root, address insolvent) = _seedTiedKeys();
        address supplier = _actor("supplier");
        _fund(m.loanToken, supplier, 2 * TIED_VALUE);
        m.coreSupply(supplier, 2 * TIED_VALUE);

        // The fewest borrow shares whose down-rounded value equals the collateral value.
        MorphoMarket memory mkt = m.core.market(m.id);
        uint256 cut = Math.mulDiv(
            TIED_VALUE, uint256(mkt.totalBorrowShares) + 1e6, uint256(mkt.totalBorrowAssets) + 1, Math.Rounding.Ceil
        );
        assertLt(cut, m.core.position(m.id, insolvent).borrowShares, "setup: the cut is partial");

        (uint256 seized,) = m.coreSettle(supplier, insolvent, cut, supplier);

        assertEq(seized, TIED_COLLATERAL, "the partial cut seizes all collateral");
        _assertDebtLeftOnZeroCollateral(root, insolvent);
    }

    /// @dev A targeted vault settle takes all collateral of an insolvent non-root borrower
    ///      and leaves debt that no queue entry or gate tracks.
    function test_tiedKeyPersonalVaultSettle_leavesDebtOnZeroCollateral() public {
        Market storage m = _m();
        (address root, address insolvent) = _seedTiedKeys();
        address lender = _actor("lender");

        // A claim 4 loan units above the collateral value. One collateral unit is worth 10 loan units (`TIED_PRICE`).
        // The budgeted cut still seizes everything and stays partial.
        uint256 shares = Erc4626Math.toShares(m.vault, TIED_VALUE + 4, Math.Rounding.Ceil);
        address[] memory borrowers = new address[](1);
        borrowers[0] = insolvent;

        (, uint256 seized,) = m.settle(lender, shares, borrowers, lender);

        assertEq(seized, TIED_COLLATERAL, "the budgeted cut seizes all collateral");
        _assertDebtLeftOnZeroCollateral(root, insolvent);
    }

    // ── Sub-unit root: the rounded bad-debt check blocks every settlement ──

    /// @dev Known issue: a queue root can be solvent in exact math while its collateral value rounds down to zero. Such
    ///      a root counts as bad debt. It blocks the settlement of every other borrower until someone repays it.
    ///      Root cause: `_isBadDebt` compares the debt rounded up by `toAssetsUp` with the collateral value rounded
    ///      down by `_collateralValue`, in whole loan units. `_handleSettle` runs that check on `peekRoot()` for
    ///      every cut. `allowedSliceAssets` also returns no slice when the collateral value is zero, so the root
    ///      itself cannot be cut.
    ///      Same cause: any root whose exact debt and collateral value have no whole loan unit between them, not
    ///      only a sub-unit root. Such a root can come from a partial liquidation, a partial repay, or a price
    ///      move. It blocks vault `settle` of any borrower, the `fallbackExit` settle leg, and a direct core
    ///      `settle` by any supplier, and `hasBadDebt` reports true. A repay of the root by any account
    ///      clears it.
    function test_subUnitSolventRoot_blocksOtherSettlementUntilRepaid() public {
        Market storage m = _m();
        (address lender, uint256 shares, address root, address healthy) = _seedSubUnitRoot();

        // The root is solvent in exact math: shares * (A + 1) * SCALE <= collateral * price * (S + V).
        MorphoMarket memory mkt = m.accruedMarket();
        assertLe(
            SUB_UNIT_SHARES * (uint256(mkt.totalBorrowAssets) + 1) * 1e36,
            uint256(m.core.position(m.id, root).collateral) * SUB_UNIT_PRICE * (uint256(mkt.totalBorrowShares) + 1e6),
            "setup: the root is solvent in exact math"
        );
        assertTrue(m.controller.hasBadDebt(), "the rounded check reports bad debt at the root");
        (, SettlementSlice memory rootSlice) = m.controller.nextSettlementBorrower(0);
        assertEq(rootSlice.borrowShares, 0, "the root itself has no executable cut");

        m.setSettlementLtv(healthy, 1);
        assertGt(m.controller.positionOf(healthy).personalSliceAssets, 0, "setup: the healthy borrower is eligible");
        address[] memory borrowers = new address[](1);
        borrowers[0] = healthy;

        vm.prank(lender);
        vm.expectRevert(ILidoLendMarketController.SettlementBadDebt.selector);
        m.vault.settle(shares / 100, borrowers, lender, lender);

        // Anyone can clear the root: its whole residual debt costs one loan unit.
        assertEq(m.repayAssets(SUB_UNIT_SHARES), 1, "the residual debt costs one loan unit");
        m.repay(root, SUB_UNIT_SHARES);
        assertFalse(m.controller.hasBadDebt(), "the repay clears the gate");
        (address newRoot,) = m.controller.nextSettlementBorrower(0);
        assertEq(newRoot, healthy, "the healthy borrower is the root now");

        (,, uint256 debtCanceled) = m.settle(lender, shares / 100, borrowers, lender);
        assertGt(debtCanceled, 0, "the same settle now cancels debt");
    }

    /// @dev A root with one collateral unit and `SUB_UNIT_SHARES` of debt, and a healthy borrower behind it. A
    ///      liquidation leaves one collateral unit, and a repay leaves the residual shares.
    function _seedSubUnitRoot() private returns (address lender, uint256 shares, address root, address healthy) {
        Market storage m = _m();
        lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        shares = m.vaultDeposit(lender, 1000 ether);

        root = _actor("subUnitRoot");
        healthy = _actor("healthy");
        _fund(m.collateralToken, root, 100 ether);
        m.supplyCollateral(root, 100 ether);
        _fund(m.collateralToken, healthy, 100 ether);
        m.supplyCollateral(healthy, 100 ether);
        m.activateCollateral();
        // 70% LTV. 100 collateral is worth at least 30 loan units at any seeded price, so 5 is a low LTV.
        m.borrow(root, 100 ether * oraclePrice / 1e36 * 70 / 100);
        m.borrow(healthy, 5 ether);

        // At about 97% LTV a seizure of all but one collateral unit repays less than the debt (1 / incentive is
        // 94% at this LLTV), so the liquidation leaves debt on one collateral unit and no bad debt.
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 70 / 97);
        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
        m.liquidate(keeper, root, 100 ether - 1, 0);
        assertEq(m.core.position(m.id, root).collateral, 1, "setup: one collateral unit left");

        uint256 residual = m.core.position(m.id, root).borrowShares;
        assertGt(residual, SUB_UNIT_SHARES, "setup: the liquidation left more debt than the target");
        m.repay(root, residual - SUB_UNIT_SHARES);
        MockPriceOracle(address(m.oracle)).setPrice(SUB_UNIT_PRICE);

        (address queueRoot,) = m.controller.nextSettlementBorrower(0);
        assertEq(queueRoot, root, "setup: the sub-unit position is the queue root");
        assertEq(m.core.position(m.id, root).borrowShares, SUB_UNIT_SHARES, "setup: residual shares");
    }

    // ── Collateral with a transfer callback: settle pays out before the vault books it ──

    /// @dev A redeem from the collateral transfer callback of `settle` pays the same as a redeem after the settle,
    ///      within one loan unit. Market creation through the facade requires `MARKET_CREATOR_ROLE`.
    function test_reentrantRedeemInSettleCallback_paysSameAsRedeemAfter() public {
        MockERC20 loan = new MockERC20("Loan2", "LOAN2", 18);
        CallbackERC20 collateral = new CallbackERC20("Hooked Collateral", "HCOLL", 18);
        Market storage m = _addMarket(_defaultConfig(address(loan), address(collateral), address(collateral)));

        ReentrantRedeemer attacker = new ReentrantRedeemer(m.vault);
        collateral.setHookedReceiver(address(attacker));
        _fund(m.loanToken, address(attacker), 1000 ether);
        uint256 shares = m.vaultDeposit(address(attacker), 1000 ether);

        address borrower = _actor("hookedBorrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, 100 ether * oraclePrice / 1e36 * 40 / 100);
        m.setSettlementLtv(borrower, 1);

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256 settleShares = shares / 100;
        uint256 redeemShares = shares / 10;

        // Reference: the callback does nothing, and the lender redeems after the settle.
        uint256 snapshot = vm.snapshotState();
        vm.prank(address(attacker));
        m.vault.settle(settleShares, borrowers, address(attacker), address(attacker));
        vm.prank(address(attacker));
        uint256 referencePayout = m.vault.redeem(redeemShares, address(attacker), address(attacker));
        assertFalse(attacker.reentered(), "setup: the reference path does not re-enter");
        vm.revertToState(snapshot);

        attacker.arm(redeemShares);
        vm.prank(address(attacker));
        (uint256 sharesBurned, uint256 seized,) =
            m.vault.settle(settleShares, borrowers, address(attacker), address(attacker));

        assertTrue(attacker.reentered(), "the collateral transfer gave control to the receiver");
        assertGt(seized, 0, "the settle seized collateral");
        assertEq(sharesBurned, settleShares, "the settle burned the whole request");
        assertApproxEqAbs(attacker.reentrantPayout(), referencePayout, 1, "the reentrant redeem pays the same");
        assertEq(
            m.vault.balanceOf(address(attacker)), shares - settleShares - redeemShares, "both burns hit the lender"
        );
        assertLe(
            m.vault.managedSupplyShares(),
            m.core.position(m.id, address(m.vault)).supplyShares,
            "managed shares stay within the core position"
        );
    }

    /// @dev Withdrawing collateral under open debt may not leave active collateral below the activation
    ///      threshold (`minActivationAmount`, 10 ether): `_getMaxBorrow` returns 0 for sub-threshold active
    ///      collateral, so the debt no longer clears the LLTV health check and the withdraw reverts.
    function testRevert_withdrawCollateral_belowFloorWithOpenDebt() public {
        Market storage m = _m();
        (, address borrower,) = _seed(100 ether, 100); // tiny debt -> lots of health headroom

        // Leaving 5 ether active (< the 10 ether activation threshold) zeroes borrow capacity, so the open debt
        // fails the health gate.
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.withdrawCollateral(m.params, 95 ether, borrower, borrower);
    }

    /// @dev A borrower can withdraw active collateral below the threshold while debt-free (the withdraw health
    ///      gate only bites with open debt), but then cannot open a loan against it: `_getMaxBorrow` is 0 for
    ///      sub-threshold active collateral, so the borrow fails the health check.
    function testRevert_borrow_subFloorActiveAfterDebtFreeWithdraw() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 50 ether);
        m.supplyCollateral(borrower, 50 ether);
        m.activateCollateral();

        // Debt-free, so withdrawing active collateral below the threshold IS allowed.
        vm.prank(borrower);
        m.core.withdrawCollateral(m.params, 45 ether, borrower, borrower);
        assertEq(m.controller.positionOf(borrower).active, 5 ether, "active collateral now below the threshold");

        // Opening a loan against that sub-threshold active collateral is rejected (zero capacity).
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, 0.5 ether, 0, borrower, borrower);
    }

    /// @dev A fresh sub-threshold deposit stays dust (active 0) and cannot be borrowed against: zero active
    ///      collateral means zero borrow capacity.
    function testRevert_borrow_freshDustCollateral() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 5 ether); // < 10 threshold -> dust
        m.supplyCollateral(borrower, 5 ether);
        m.activateCollateral();
        assertEq(m.controller.positionOf(borrower).active, 0, "sub-threshold deposit never activates");

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, 1 ether, 0, borrower, borrower);
    }

    /// @dev Threshold boundary: active collateral exactly at `minActivationAmount` (10 ether) has non-zero
    ///      capacity (`_getMaxBorrow` gates on strict `<`), so a small borrow goes through.
    function test_borrow_atFloorExactly_passes() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 10 ether); // exactly at the threshold
        m.supplyCollateral(borrower, 10 ether);
        m.activateCollateral();

        // Active collateral 10 == threshold 10 -> not below, so capacity is non-zero and a tiny borrow succeeds.
        vm.prank(borrower);
        m.core.borrow(m.params, 1 ether, 0, borrower, borrower);
        assertEq(m.controller.positionOf(borrower).debtAssets, 1 ether, "borrow at the exact threshold succeeds");
    }

    /// @dev Contrast (accepted behaviour): liquidation is a FORCED path that does NOT re-check the floor, so a
    ///      partial seize MAY leave a debt-bearing position below the floor. The residual is un-reactivatable
    ///      dust under a small debt; only the voluntary borrow/withdraw paths are gated.
    function test_liquidation_mayLeaveDebtBearingSubFloorCollateral() public {
        Market storage m = _m();
        (, address borrower,) = _seed(50 ether, 8000); // 50 collateral, ~80% of LLTV-max

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 75 / 100); // unhealthy, still solvent
        m.accrueInterest();

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1_000_000 ether);
        vm.startPrank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        m.core.liquidate(m.params, borrower, 41 ether, 0, ""); // partial seize -> ~9 left, residual debt
        vm.stopPrank();

        assertLt(m.core.position(m.id, borrower).collateral, 10 ether, "forced seize left sub-floor collateral");
        assertGt(m.core.position(m.id, borrower).borrowShares, 0, "with residual debt -> accepted forced-path state");
    }

    /// @dev Pinned from the solvency fuzz: seizing the FULL collateral of a SOLVENT (unhealthy-but-not-
    ///      underwater) position implies repaying more debt than the borrower owes. The controller's liquidate
    ///      hook rejects the over-repay with `PositionAccountingMismatch` before the core underflows.
    function testRevert_liquidate_seizeAllOnSolventPosition_overRepays() public {
        Market storage m = _m();
        (, address borrower,) = _seed(100 ether, 8000); // ~80% of LLTV-max

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 75 / 100); // unhealthy, still solvent (coll > debt)
        m.accrueInterest();

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1_000_000 ether);
        vm.startPrank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.expectRevert(ILidoLendMarketController.PositionAccountingMismatch.selector);
        m.core.liquidate(m.params, borrower, 100 ether, 0, ""); // seize ALL -> over-repay on a solvent position
        vm.stopPrank();
    }

    /// @dev The over-seize revert above is NOT a stuck-position bug: the SAME solvent position liquidates fine
    ///      when the keeper specifies the debt to repay (`repaidShares`) instead of over-seizing. The core
    ///      seizes only the incentivized collateral for that debt and leaves the surplus with the borrower.
    function test_liquidate_solventPosition_byRepaidShares_succeeds() public {
        Market storage m = _m();
        (, address borrower,) = _seed(100 ether, 8000);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 75 / 100); // unhealthy, still solvent
        m.accrueInterest();

        uint256 shares = m.core.position(m.id, borrower).borrowShares;
        uint256 colBefore = m.core.position(m.id, borrower).collateral;

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1_000_000 ether);
        vm.startPrank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        (uint256 seized,) = m.core.liquidate(m.params, borrower, 0, shares, ""); // repay the WHOLE debt
        vm.stopPrank();

        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "debt fully cleared");
        assertEq(colBefore - m.core.position(m.id, borrower).collateral, seized, "collateral delta == seized");
        assertLt(seized, colBefore, "solvent: only the incentivized slice is seized, not all collateral");
        assertGt(m.core.position(m.id, borrower).collateral, 0, "borrower keeps the surplus collateral");
    }

    /// @dev The ASSETS path works too — it is not "shares only". Seizing a modest `seizedAssets` (whose
    ///      incentivized value is under the debt) liquidates partially; only over-seizing past the debt
    ///      reverts. So both liquidation parameters are usable; over-seize is the keeper's input error.
    function test_liquidate_solventPosition_bySeizedAssets_succeeds() public {
        Market storage m = _m();
        (, address borrower,) = _seed(100 ether, 8000);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 75 / 100); // unhealthy, still solvent
        m.accrueInterest();

        uint256 sharesBefore = m.core.position(m.id, borrower).borrowShares;
        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1_000_000 ether);
        vm.startPrank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        (uint256 seized, uint256 repaid) = m.core.liquidate(m.params, borrower, 10 ether, 0, ""); // assets path
        vm.stopPrank();

        assertEq(seized, 10 ether, "assets path seizes exactly the requested collateral");
        assertGt(repaid, 0, "and repays the corresponding debt");
        assertLt(m.core.position(m.id, borrower).borrowShares, sharesBefore, "partial seize -> debt reduced");
        assertGt(m.core.position(m.id, borrower).borrowShares, 0, "but not fully cleared (partial)");
    }

    /// @dev A borrower opts into a personal settlement LTV; it is stored and read back, and a value at/above
    ///      WAD is rejected.
    function test_setSettlementLtv_storesAndRejectsOutOfRange() public {
        Market storage m = _m();
        address borrower = _actor("borrower");

        vm.prank(borrower);
        m.controller.setSettlementLtv(0.5e18);
        (uint256 ltv,) = m.controller.settlementLtv(borrower);
        assertEq(ltv, 0.5e18, "personal settlement LTV stored");

        vm.prank(borrower);
        vm.expectRevert(SettlementQueueLib.SettlementLtvOutOfRange.selector);
        m.controller.setSettlementLtv(1e18); // >= WAD
    }

    /// @dev Targeted settlement requires a personal settlement LTV; queue-root status alone does not qualify. A
    ///      NON-root borrower is initially ineligible, then opts in and the same call cancels the predicted slice.
    function test_settle_nonRootReverts_thenEligibleViaPersonalLtv() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        uint256 shares = m.vaultDeposit(lender, 1000 ether);

        // Two borrowers at different risk keys (80/400 vs 80/800); 400/800 keep an 80 borrow within LLTV-max
        // at any seeded price. The queue root is read from the contract, not assumed.
        address a = _actor("a");
        _fund(m.collateralToken, a, 400 ether);
        m.supplyCollateral(a, 400 ether);
        address b = _actor("b");
        _fund(m.collateralToken, b, 800 ether);
        m.supplyCollateral(b, 800 ether);
        m.activateCollateral();
        m.borrow(a, 80 ether);
        m.borrow(b, 80 ether);

        (address root,) = m.controller.nextSettlementBorrower(0);
        address nonRoot = root == a ? b : a;
        address[] memory bs = new address[](1);
        bs[0] = nonRoot;

        // Ineligible non-root -> the vault batch settles nothing and reverts atomically.
        vm.expectRevert(ILidoLendERC4626.NothingSettled.selector);
        vm.prank(lender);
        m.vault.settle(shares, bs, lender, lender);

        // It opts into a settlement LTV below its current LTV -> eligible -> cancels exactly the slice.
        vm.prank(nonRoot);
        // Any nonzero-debt position is above this target, regardless of the seeded oracle price.
        m.controller.setSettlementLtv(1);
        uint256 sliceAssets = m.controller.positionOf(nonRoot).personalSliceAssets;
        address[] memory mixed = new address[](2);
        mixed[0] = _actor("empty-settlement-target");
        mixed[1] = nonRoot;
        vm.prank(lender);
        (,, uint256 cancelledAfter) = m.vault.settle(shares, mixed, lender, lender);
        assertEq(
            cancelledAfter,
            sliceAssets,
            "mixed batch skips the empty target and cancels the eligible personal-LTV slice exactly"
        );
    }

    /// @dev Probes whether the `UnknownHookEvent` body guard is reachable with an
    ///      unknown hook value. Verified empirically (Solidity can't cast an out-of-range enum, so we
    ///      hand-craft calldata and call `on()` as the core):
    ///        - a VALID skipped event (Withdraw=1) reaches the body and no-ops → the dispatch IS exercised;
    ///        - an OUT-OF-RANGE value (9, beyond the 9-member enum) is rejected by the ABI enum-decode and
    ///          reverts EMPTY (this repo is `via_ir = false`; the legacy pipeline reverts `revert(0,0)`, not
    ///          `Panic(0x21)`) BEFORE the body — so the `UnknownHookEvent` revert is a fail-closed guard that
    ///          cannot fire with the current enum. Confirmed: it is genuinely unreachable, not just untested.
    function test_on_outOfRangeHookEvent_isRejectedAtDecode() public {
        Market storage m = _m();

        // Control: a valid skipped event reaches the body and succeeds (no-op).
        vm.prank(address(m.core));
        (bool okValid,) = address(m.controller)
            .call(abi.encodeWithSignature("on(bytes32,uint8,bytes)", Id.unwrap(m.id), uint8(1), bytes("")));
        assertTrue(okValid, "valid skipped hook (Withdraw) reaches the body and no-ops");

        // Out-of-range hook event: rejected at ABI enum-decode, before the body.
        vm.prank(address(m.core));
        (bool okBad, bytes memory ret) = address(m.controller)
            .call(abi.encodeWithSignature("on(bytes32,uint8,bytes)", Id.unwrap(m.id), uint8(9), bytes("")));
        assertFalse(okBad, "out-of-range HookEvent reverts");
        assertEq(ret.length, 0, "reverts empty at enum-decode (legacy pipeline), not the UnknownHookEvent body");
    }

    /// @dev Setting LTV to 0 clears the opt-in.
    function test_setSettlementLtv_zeroClears() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        vm.prank(borrower);
        m.controller.setSettlementLtv(0.6e18);
        vm.prank(borrower);
        m.controller.setSettlementLtv(0);
        (uint256 ltv,) = m.controller.settlementLtv(borrower);
        assertEq(ltv, 0, "zero clears the personal LTV");
    }
}
