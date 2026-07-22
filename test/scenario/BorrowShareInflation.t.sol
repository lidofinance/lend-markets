// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

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
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();

        _fund(m.loanToken, borrower, 1 ether);
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
    ///      is attempted through the contract's own guards (reverts are skipped).
    function testFuzz_noShortChainInflatesShares(uint256 seed) public {
        Market storage m = _m();
        address attacker = _actor("attacker");
        _fundedBorrower(attacker, 100 ether);

        vm.prank(attacker);
        m.core.borrow(m.params, BORROW_AMOUNT, 0, attacker, attacker);

        for (uint256 i = 0; i < 150; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 amt = 1 + ((r >> 8) % 1e12);
            vm.prank(attacker);
            if (r % 4 == 0) {
                try m.core.borrow(m.params, 1 + (amt % 1 ether), 0, attacker, attacker) {} catch {}
            } else if (r % 4 == 1) {
                try m.core.borrow(m.params, 0, amt, attacker, attacker) {} catch {}
            } else if (r % 4 == 2) {
                uint256 s = m.core.position(m.id, attacker).borrowShares;
                if (s > 1) try m.core.repay(m.params, 0, 1 + (amt % (s - 1)), attacker, "") {} catch {}
            } else {
                uint256 tba = m.core.market(m.id).totalBorrowAssets;
                if (tba > 0) try m.core.repay(m.params, 1 + (amt % tba), 0, attacker, "") {} catch {}
            }

            // Far below any legitimate short-chain total (a whale borrow mints ~amount*VS) and the ~1e38 uint128
            // ceiling: a fast/cheap inflation would blow past this well within 150 ops.
            assertLt(m.core.market(m.id).totalBorrowShares, 1e30, "no short chain inflates borrow shares");
        }
    }

    // ── borrow-share-rate ceiling ──

    /// @dev A borrower can always fully close their own position, even with a co-borrower still outstanding.
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
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 22 / 100); // solvent-but-unhealthy
        m.accrueInterest();

        // Targeted settle of the distressed borrower — the ceiling's settle transition-check must not block it.
        address[] memory bs = new address[](1);
        bs[0] = borrower;
        uint256 lenderShares = m.vault.balanceOf(lender);
        (uint256 burned,,, uint256 debtCanceled) = m.settle(lender, lenderShares / 2, bs, lender);
        assertGt(burned, 0, "settle stayed live with the ceiling active");
        assertGt(debtCanceled, 0, "settle cancelled debt");

        // fallbackExit the rest — also stays live.
        uint256 remaining = m.vault.balanceOf(lender);
        (uint256 exitBurned,,,) = m.fallbackExit(lender, remaining, lender, 0);
        assertGt(exitBurned, 0, "fallbackExit stayed live with the ceiling active");
    }
}
