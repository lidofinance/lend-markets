// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IMorphoBase, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ErrorsLib} from "@lido-lend/src/libraries/ErrorsLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice Borrow-share inflation defense. Rounding can strand borrow shares while total borrow assets approach
///         zero, making a subsequent borrow mint a disproportionate number of shares. The borrow-share-rate
///         ceiling blocks borrow/repay/settle from pushing the virtual share rate over the cap. Liquidation is
///         exempt so it stays live, and a repay/settle that starts already over the cap is allowed when it reduces
///         the rate so a stranded state can be cleaned up.
contract BorrowShareInflationTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev Morpho virtual-shares constant: a fresh borrow of `a` assets mints exactly `a * VIRTUAL_SHARES`.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant BORROW_AMOUNT = 1e5;
    /// @dev Spec ceiling: ten times the core's natural 1e6 shares per raw loan-asset unit.
    uint256 internal constant MAX_BORROW_SHARE_RATE = 1e7;
    /// @dev Shares at which a book holding one raw unit sits exactly at the ceiling: `(S + 1e6) == 1e7 * (1 + 1)`.
    uint256 internal constant AT_CAP_SHARES_ONE_UNIT = 19_000_000;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender liquidity + a matured collateral position for `borrower`, and the core approved to pull repays.
    function _fundedBorrower(address borrower, uint256 collat) internal {
        _fundedBorrower(_m(), borrower, collat);
    }

    /// @dev Amounts in whole loan tokens, so the helper serves a market of any loan decimals.
    function _fundedBorrower(Market storage m, address borrower, uint256 collat) internal {
        uint256 unit = 10 ** MockERC20(address(m.loanToken)).decimals();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 * unit);
        m.vaultDeposit(lender, 1000 * unit);

        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();

        _fund(m.loanToken, borrower, unit);
        vm.prank(borrower);
        m.loanToken.approve(address(m.core), type(uint256).max);
    }

    /// @dev A share-anchored borrow whose assets round to zero is rejected outright.
    function test_zeroAssetShareBorrow_reverts() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.ZeroBorrowAssets.selector);
        m.core.borrow(m.params, 0, VIRTUAL_SHARES - 1, borrower, borrower); // toAssetsDown -> 0
    }

    /// @dev A nonzero borrow on a fresh market is allowed while its resulting borrow-share rate stays under the cap.
    function test_freshMarket_nonzeroBorrowWithinRateCeiling_allowed() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);

        vm.prank(borrower);
        (uint256 assets,) = m.core.borrow(m.params, 1, 0, borrower, borrower);
        assertEq(assets, 1, "nonzero borrow accepted");
    }

    /// @dev Fuzz: no bounded random chain of borrows and repays inflates the borrow-share counter. Each operation
    ///      goes through the contract's own guards. Borrow and repay both enforce the rate guard, so every step
    ///      keeps the rate within the cap. Borrows and repays must both succeed, so the chain is not borrow-only.
    function testFuzz_noShortChainInflatesShares(uint256 seed) public {
        Market storage m = _m();
        address attacker = _actor("attacker");
        _fundedBorrower(attacker, 100 ether);

        vm.prank(attacker);
        m.core.borrow(m.params, BORROW_AMOUNT, 0, attacker, attacker);

        uint256 borrows;
        uint256 repays;
        for (uint256 i = 0; i < 150; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 amt = 1 + ((r >> 8) % 1e12);
            uint256 s = m.core.position(m.id, attacker).borrowShares;
            uint256 tba = m.core.market(m.id).totalBorrowAssets;
            if (r % 4 == 0) {
                borrows += _attempt(
                    attacker, abi.encodeCall(IMorphoBase.borrow, (m.params, 1 + (amt % 1 ether), 0, attacker, attacker))
                );
            } else if (r % 4 == 1) {
                borrows += _attempt(
                    attacker, abi.encodeCall(IMorphoBase.borrow, (m.params, 0, amt, attacker, attacker))
                );
            } else if (r % 4 == 2) {
                if (s > 1) {
                    repays += _attempt(
                        attacker, abi.encodeCall(IMorphoBase.repay, (m.params, 0, 1 + (amt % (s - 1)), attacker, ""))
                    );
                }
            } else if (tba > 0) {
                repays += _attempt(
                    attacker, abi.encodeCall(IMorphoBase.repay, (m.params, 1 + (amt % tba), 0, attacker, ""))
                );
            }

            MorphoMarket memory mk = m.core.market(m.id);
            assertLe(
                mk.totalBorrowShares + VIRTUAL_SHARES,
                MAX_BORROW_SHARE_RATE * (mk.totalBorrowAssets + 1),
                "every step keeps the rate within the cap"
            );
            // Far below any legitimate short-chain total (a whale borrow mints ~amount*VS) and the ~1e38 uint128
            // ceiling: a fast/cheap inflation would blow past this well within 150 ops.
            assertLt(mk.totalBorrowShares, 1e30, "no short chain inflates borrow shares");
        }
        assertGt(borrows, 0, "the chain borrowed");
        assertGt(repays, 0, "the chain repaid");
    }

    /// @dev Calls the core as `attacker` and returns 1 on success. A step may revert only as the spec allows: a move
    ///      over the rate cap, or a share borrow that rounds to zero assets. Any other revert fails the test.
    function _attempt(address attacker, bytes memory call) private returns (uint256) {
        vm.prank(attacker);
        (bool ok, bytes memory reason) = address(_m().core).call(call);
        if (ok) return 1;
        bytes4 selector = bytes4(reason);
        assertTrue(
            selector == ILidoLendMarketController.BorrowShareRateExceeded.selector
                || selector == ILidoLendMarketController.ZeroBorrowAssets.selector,
            "unexpected revert in the chain"
        );
        return 0;
    }

    // ── borrow-share-rate ceiling ──

    /// @dev Below the rate cap, a borrower can fully close their own position while a co-borrower still owes debt.
    function test_repay_fullClose_withCoborrower_allowed() public {
        Market storage m = _m();
        address a = _actor("a");
        address b = _actor("b");
        _fundedBorrower(a, 100 ether);
        _fundedBorrower(b, 100 ether);

        vm.prank(a);
        (, uint256 aShares) = m.core.borrow(m.params, BORROW_AMOUNT, 0, a, a);
        vm.prank(b);
        m.core.borrow(m.params, BORROW_AMOUNT, 0, b, b);

        vm.prank(a);
        m.core.repay(m.params, 0, aShares, a, ""); // full close while b lingers
        assertEq(m.core.position(m.id, a).borrowShares, 0, "a fully closed its position");
        assertGt(m.core.market(m.id).totalBorrowShares, 0, "b still outstanding");
    }

    /// @dev The near-full-repay doubling cycle: at `TBA == 0` borrow a fixed amount, then repay all but the
    ///      virtual remainder so `TBA` returns to 0 while the virtual share total ~doubles. Without a ceiling this
    ///      reaches the `uint128` overflow in 92 cycles; the borrow-share-rate ceiling reverts the near-full repay
    ///      once the rate would cross the cap, far short of overflow.
    function test_inflation_doublingCycle_stoppedByCeiling() public {
        Market storage m = _m();
        address attacker = _actor("attacker");
        _fundedBorrower(attacker, 100 ether);

        uint256 cap = m.controller.MAX_BORROW_SHARE_RATE();
        uint256 completed;
        bool blockedByRate;
        for (uint256 c = 0; c < 92; ++c) {
            uint256 sBefore = m.core.market(m.id).totalBorrowShares; // TBA == 0 at the top of each cycle
            vm.prank(attacker);
            (, uint256 q) = m.core.borrow(m.params, BORROW_AMOUNT, 0, attacker, attacker);
            uint256 x = sBefore + VIRTUAL_SHARES;
            uint256 r = q - (x - 1); // strand (x - 1) virtual shares, driving TBA back to 0
            vm.prank(attacker);
            try m.core.repay(m.params, 0, r, attacker, "") {
                ++completed;
            } catch (bytes memory reason) {
                blockedByRate = bytes4(reason) == ILidoLendMarketController.BorrowShareRateExceeded.selector;
                break;
            }
        }

        assertTrue(blockedByRate, "the near-full repay is blocked by the borrow-share-rate ceiling");
        assertLt(completed, 92, "blocked well before the uint128 overflow at cycle 93");

        // The market is not bricked: the ceiling held, so the rate never crossed the cap and the reverted repay
        // rolled its stranding back. Borrowing still works.
        (uint256 tba, uint256 tbs) = (m.core.market(m.id).totalBorrowAssets, m.core.market(m.id).totalBorrowShares);
        assertLe(tbs + VIRTUAL_SHARES, cap * (tba + 1), "rate stayed within the cap");
    }

    /// @dev A partial repay that stays under the borrow-share-rate cap is allowed.
    function test_partialRepay_underRateCeiling_allowed() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);
        _fund(m.loanToken, borrower, 10 ether);

        vm.prank(borrower);
        (, uint256 shares) = m.core.borrow(m.params, 10 ether, 0, borrower, borrower);
        vm.prank(borrower);
        m.core.repay(m.params, 0, shares / 2, borrower, "");
        assertGt(m.core.market(m.id).totalBorrowAssets, 0, "partial debt remains");
    }

    /// @dev A full close by assets and by shares both bring the rate back to the natural rate (not over the cap),
    ///      so both are allowed.
    function test_fullRepay_byAssetsAndByShares_allowed() public {
        Market storage m = _m();
        address a = _actor("a");
        address b = _actor("b");
        _fundedBorrower(a, 100 ether);
        _fundedBorrower(b, 100 ether);
        _fund(m.loanToken, a, 10 ether);
        _fund(m.loanToken, b, 10 ether);

        vm.prank(a);
        (, uint256 aShares) = m.core.borrow(m.params, 5 ether, 0, a, a);
        vm.prank(b);
        m.core.borrow(m.params, 5 ether, 0, b, b);

        // Full close by shares.
        vm.prank(a);
        m.core.repay(m.params, 0, aShares, a, "");
        assertEq(m.core.position(m.id, a).borrowShares, 0, "a closed by shares");

        // Full close by assets (repay the whole debt in assets).
        uint256 bDebt = m.repayAssets(m.core.position(m.id, b).borrowShares);
        _fund(m.loanToken, b, bDebt);
        vm.prank(b);
        m.core.repay(m.params, bDebt, 0, b, "");
        assertEq(m.core.position(m.id, b).borrowShares, 0, "b closed by assets");
    }

    /// @dev A multi-borrower sequence alternating full closes and partial repays never trips the ceiling: with
    ///      more than one borrower, total borrow assets never reach the degenerate zero-with-stranded-shares state.
    function test_multiBorrower_alternatingClosesAndPartials_allowed() public {
        Market storage m = _m();
        address a = _actor("a");
        address b = _actor("b");
        _fundedBorrower(a, 100 ether);
        _fundedBorrower(b, 100 ether);
        _fund(m.loanToken, a, 20 ether);
        _fund(m.loanToken, b, 20 ether);

        vm.prank(a);
        (, uint256 aShares) = m.core.borrow(m.params, 8 ether, 0, a, a);
        vm.prank(b);
        m.core.borrow(m.params, 8 ether, 0, b, b);

        vm.prank(a);
        m.core.repay(m.params, 0, aShares / 2, a, ""); // a partial

        uint256 bShares = m.core.position(m.id, b).borrowShares;
        vm.prank(b);
        m.core.repay(m.params, 0, bShares, b, ""); // b full close (a lingers)

        uint256 aRemaining = m.core.position(m.id, a).borrowShares;
        vm.prank(a);
        m.core.repay(m.params, 0, aRemaining, a, ""); // a full close -> market empty
        assertEq(m.core.market(m.id).totalBorrowShares, 0, "market fully unwound with no revert");
    }

    /// @dev Repay must not depend on the oracle: the rate ceiling reads only borrow totals. A repay succeeds even
    ///      while the oracle reverts, so a borrower can always reduce debt during an outage.
    function test_repay_worksWhileOracleReverts() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);
        _fund(m.loanToken, borrower, 10 ether);
        vm.prank(borrower);
        (, uint256 shares) = m.core.borrow(m.params, 10 ether, 0, borrower, borrower);

        // Oracle down: every price() read reverts.
        vm.mockCallRevert(address(m.oracle), abi.encodeWithSignature("price()"), "oracle down");

        vm.prank(borrower);
        m.core.repay(m.params, 0, shares, borrower, "");
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "repaid fully while the oracle reverted");
    }

    /// @dev Voluntary settlement and fallbackExit stay live with the ceiling active: a distressed borrower is
    ///      settled and the lender fallback-exits. Neither is blocked because the settle transition keeps the rate
    ///      at the natural level.
    function test_settlementAndFallbackExit_liveWithCeiling() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, 20 ether);
        MockPriceOracle(address(m.oracle)).setPrice(0.22e36); // solvent-but-unhealthy
        m.accrueInterest();
        m.setSettlementLtv(borrower, 0.8e18);

        // Targeted settle of the distressed borrower — the ceiling's settle transition-check must not block it.
        address[] memory bs = new address[](1);
        bs[0] = borrower;
        uint256 lenderShares = m.vault.balanceOf(lender);
        (uint256 burned,, uint256 debtCanceled) = m.settle(lender, lenderShares / 2, bs, lender);
        assertGt(burned, 0, "settle stayed live with the ceiling active");
        assertGt(debtCanceled, 0, "settle cancelled debt");

        // fallbackExit the rest — also stays live.
        uint256 remaining = m.vault.balanceOf(lender);
        (uint256 exitBurned,,,) = m.fallbackExit(lender, remaining, lender, 0);
        assertGt(exitBurned, 0, "fallbackExit stayed live with the ceiling active");
    }

    /// @dev Liquidation is exempt from the guard, so a bad-debt liquidation can take the market over the cap where a
    ///      repay cannot. Over the cap every borrow reverts. An exact-share repay of the stranded shares empties the
    ///      book, and the same borrow then succeeds.
    function test_badDebtLiquidation_crossesRateCap_blocksBorrowsUntilShareRepay() public {
        Market storage m = _m();
        address victim = _actor("victim");
        address bystander = _actor("bystander");
        address keeper = _actor("keeper");
        _fundedBorrower(victim, 50 ether);
        _fundedBorrower(bystander, 50 ether);
        _fund(m.loanToken, keeper, 1 ether);

        // Two 10-unit borrows mint 1e7 shares each. Each one-share repay costs one raw unit (round-up).
        m.borrow(bystander, 10);
        m.borrow(victim, 10);
        for (uint256 i; i < 18; ++i) {
            m.repay(bystander, 1);
        }
        MorphoMarket memory mk = m.core.market(m.id);
        assertEq(mk.totalBorrowAssets, 2, "setup: two raw units left");
        assertEq(mk.totalBorrowShares, 2e7 - 18, "setup: one share left per repaid unit");
        assertLe(
            mk.totalBorrowShares + VIRTUAL_SHARES,
            MAX_BORROW_SHARE_RATE * (mk.totalBorrowAssets + 1),
            "setup: at most the cap"
        );
        vm.prank(bystander);
        vm.expectRevert(ILidoLendMarketController.BorrowShareRateExceeded.selector);
        m.core.repay(m.params, 0, 1, bystander, ""); // A = 1 on 2e7 - 19 shares crosses the cap

        // At an oracle price of 1 the victim's collateral is worth zero, so the full seizure writes off its debt.
        MockPriceOracle(address(m.oracle)).setPrice(1);
        m.liquidateBadDebt(keeper, victim, 50 ether, 0);
        uint256 stranded = m.core.position(m.id, bystander).borrowShares;
        mk = m.core.market(m.id);
        assertEq(mk.totalBorrowAssets, 0, "no borrow assets left");
        assertEq(mk.totalBorrowShares, stranded, "only the bystander's shares are left");
        assertGt(
            mk.totalBorrowShares + VIRTUAL_SHARES,
            MAX_BORROW_SHARE_RATE * (mk.totalBorrowAssets + 1),
            "liquidation crossed the cap"
        );

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice);
        vm.prank(bystander);
        vm.expectRevert(ILidoLendMarketController.BorrowShareRateExceeded.selector);
        m.core.borrow(m.params, BORROW_AMOUNT, 0, bystander, bystander);

        m.repay(bystander, stranded);
        mk = m.core.market(m.id);
        assertEq(mk.totalBorrowShares, 0, "exact-share repay removed the stranded shares");
        assertEq(mk.totalBorrowAssets, 0, "book empty");
        m.borrow(bystander, BORROW_AMOUNT);
    }

    // ── open finding X2-C1: a close at the exact cap ──

    /// @dev Pins open finding X2-C1: at the exact cap a healthy borrower's full close reverts while other debt remains,
    ///      and liquidation cannot close it. A fix changes this outcome; update this test with the fix.
    function testFuzz_X2C1_atCapCoDebt_fullCloseReverts(uint256 coDebt) public {
        coDebt = bound(coDebt, 1, 20 ether);
        Market storage m = _m();
        (address h, uint256 hShares) = _atCapBook(m, 15 ether, coDebt);

        vm.prank(h);
        vm.expectRevert(ILidoLendMarketController.BorrowShareRateExceeded.selector);
        m.core.repay(m.params, 0, hShares, h, "");

        vm.expectRevert(bytes(ErrorsLib.HEALTHY_POSITION));
        m.core.liquidate(m.params, h, 0, hShares, "");
    }

    /// @dev Pins open finding X2-C1: at the exact cap the full close reverts until one block of interest adds a raw
    ///      unit to the 20-token book. A fix changes this outcome; update this test with the fix.
    function test_X2C1_atCapCoDebt_fullCloseSucceedsAfterOneBlock() public {
        Market storage m = _m();
        (address h, uint256 hShares) = _atCapBook(m, 15 ether, 20 ether);
        uint256 bookAssets = m.core.market(m.id).totalBorrowAssets;

        vm.prank(h);
        vm.expectRevert(ILidoLendMarketController.BorrowShareRateExceeded.selector);
        m.core.repay(m.params, 0, hShares, h, "");

        m.warpAndAccrue(12);
        assertGt(m.core.market(m.id).totalBorrowAssets, bookAssets, "setup: one block of interest accrued");
        m.repay(h, hShares);
        assertEq(m.core.position(m.id, h).borrowShares, 0, "h closed after interest");
    }

    /// @dev Pins open finding L-E5: per-block accrual books zero interest on a 6-decimal 50-token book, so the dust
    ///      close and its collateral floor stay locked. A fix changes this outcome; update this test with the fix.
    function test_LE5_sixDecimalBook_perBlockAccrual_keepsDustCloseBlocked() public {
        MockERC20 loan = new MockERC20("Loan6", "LOAN6", 6);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.lltv = 0.86e18;
        Market storage m = _addMarket(cfg);
        MockPriceOracle(address(m.oracle)).setPrice(1.05e24); // 1 COLL = 1.05 LOAN
        (address h, uint256 hShares) = _atCapBook(m, 15 ether, 50e6);
        uint256 bookAssets = m.core.market(m.id).totalBorrowAssets;

        // Control: one accrual over the same 100 blocks books interest, and the close succeeds.
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 100 * 12);
        m.repay(h, hShares);
        vm.revertToState(snap);

        for (uint256 i; i < 100; ++i) {
            m.warpAndAccrue(12);
        }
        assertEq(m.core.market(m.id).totalBorrowAssets, bookAssets, "per-block accrual books zero interest");
        vm.prank(h);
        vm.expectRevert(ILidoLendMarketController.BorrowShareRateExceeded.selector);
        m.core.repay(m.params, 0, hShares, h, "");

        // Under the 10-token activation floor the capacity is zero, so h's one raw unit of debt locks the floor.
        m.withdrawCollateral(h, 5 ether, h);
        vm.prank(h);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.withdrawCollateral(m.params, 1, h, h);
    }

    /// @dev A book exactly at the cap with `coDebt` of other debt. `h` borrows one raw unit (1e6 shares) on the empty
    ///      book, then a pumper strands shares up to the cap. At the cap a borrow mints exactly 1e7 shares per raw
    ///      unit, so the borrow of `coDebt` keeps the rate at the cap.
    function _atCapBook(Market storage m, uint256 hCollateral, uint256 coDebt)
        internal
        returns (address h, uint256 hShares)
    {
        h = _actor("h");
        address pumper = _actor("pumper");
        address coBorrower = _actor("coBorrower");
        _fundedBorrower(m, h, hCollateral);
        _fundedBorrower(m, pumper, 100 ether);
        _fundedBorrower(m, coBorrower, 100 ether);

        vm.prank(h);
        (, hShares) = m.core.borrow(m.params, 1, 0, h, h);
        assertEq(hShares, VIRTUAL_SHARES, "setup: one raw unit on the empty book mints 1e6 shares");
        _pumpTo(m, pumper, AT_CAP_SHARES_ONE_UNIT);
        m.borrow(coBorrower, coDebt);

        MorphoMarket memory mk = m.core.market(m.id);
        assertEq(mk.totalBorrowAssets, 1 + coDebt, "setup: h's raw unit plus the co-debt");
        assertEq(
            mk.totalBorrowShares + VIRTUAL_SHARES,
            MAX_BORROW_SHARE_RATE * (mk.totalBorrowAssets + 1),
            "setup: rate exactly at the cap"
        );
    }

    /// @dev Each cycle borrows `BORROW_AMOUNT`, then repays the same assets with the fewest shares the round-up
    ///      allows. The shares it does not repay stay in the book. The cycles stop at exactly `target` shares.
    function _pumpTo(Market storage m, address pumper, uint256 target) internal {
        for (uint256 cycles; m.core.market(m.id).totalBorrowShares < target; ++cycles) {
            assertLt(cycles, 20, "setup: pump does not converge");
            uint256 want = target - m.core.market(m.id).totalBorrowShares;
            vm.prank(pumper);
            (, uint256 minted) = m.core.borrow(m.params, BORROW_AMOUNT, 0, pumper, pumper);
            MorphoMarket memory mid = m.core.market(m.id);
            // The smallest share count whose round-up cost is `BORROW_AMOUNT`.
            uint256 minShares =
                (BORROW_AMOUNT - 1) * (mid.totalBorrowShares + VIRTUAL_SHARES) / (mid.totalBorrowAssets + 1) + 1;
            uint256 strand = want < minted - minShares ? want : minted - minShares;
            vm.prank(pumper);
            (uint256 paid,) = m.core.repay(m.params, 0, minted - strand, pumper, "");
            assertEq(paid, BORROW_AMOUNT, "setup: each cycle repays what it borrowed");
        }
        assertEq(m.core.market(m.id).totalBorrowShares, target, "setup: pump reached the target");
    }
}
