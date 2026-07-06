// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {console2} from "forge-std/console2.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice Borrow-share inflation defense. On a market whose total borrow assets are dust, a 1-wei borrow mints
///         a slice of the whole outstanding pool (`toSharesUp(1, TBA, TBS) ≈ TBS/TBA`); repeated with dust
///         borrows and 1-share repays it grows total borrow shares geometrically until they overflow `uint128`
///         and every borrow reverts. The controller fences this on the borrow side: while the market's total
///         borrow assets sit below `DUST_MARKET_MIN_BORROW`, a borrow must draw at least that much, so the
///         market never sits in the degenerate low-assets regime and per-borrow mints stay proportional. Repay
///         carries no strand guard.
contract BorrowShareInflationTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev Morpho virtual-shares constant: a fresh borrow of `a` assets mints exactly `a * VIRTUAL_SHARES`.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    /// @dev Read from the controller so the tests track the on-chain floor with no drift.
    uint256 internal FLOOR;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
        FLOOR = _m().controller.DUST_MARKET_MIN_BORROW();
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

    // ── dust-market floor ──

    /// @dev Below the floor a sub-floor borrow reverts; one that meets the floor is accepted.
    function test_dustMarket_borrowBelowFloor_reverts() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(ILidoLendMarketController.BorrowBelowDustMarketMinimum.selector, FLOOR, 1)
        );
        m.core.borrow(m.params, 1, 0, borrower, borrower);

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(ILidoLendMarketController.BorrowBelowDustMarketMinimum.selector, FLOOR, FLOOR - 1)
        );
        m.core.borrow(m.params, FLOOR - 1, 0, borrower, borrower);

        vm.prank(borrower);
        (uint256 assets,) = m.core.borrow(m.params, FLOOR, 0, borrower, borrower);
        assertEq(assets, FLOOR, "a borrow meeting the floor is allowed");
        assertEq(m.core.market(m.id).totalBorrowAssets, FLOOR, "TBA seeded at the floor");
    }

    /// @dev A share-anchored borrow whose assets round to zero is rejected outright.
    function test_dustMarket_zeroAssetShareBorrow_reverts() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.ZeroBorrowAssets.selector);
        m.core.borrow(m.params, 0, VIRTUAL_SHARES - 1, borrower, borrower); // toAssetsDown -> 0
    }

    /// @dev Fuzz: on a dust market every sub-floor borrow reverts and every at-or-above-floor borrow is accepted.
    function testFuzz_dustMarket_floor(uint256 amount) public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);
        amount = bound(amount, 1, 1 ether); // within collateral capacity

        vm.prank(borrower);
        if (amount < FLOOR) {
            vm.expectRevert(
                abi.encodeWithSelector(ILidoLendMarketController.BorrowBelowDustMarketMinimum.selector, FLOOR, amount)
            );
            m.core.borrow(m.params, amount, 0, borrower, borrower);
        } else {
            (uint256 assets,) = m.core.borrow(m.params, amount, 0, borrower, borrower);
            assertEq(assets, amount, "at-or-above-floor borrow accepted");
        }
    }

    /// @dev Once the market holds at least the floor in borrow assets, the guard is off and a dust borrow is fine.
    function test_populatedMarket_dustBorrowAllowed() public {
        Market storage m = _m();
        address seeder = _actor("seeder");
        address borrower = _actor("borrower");
        _fundedBorrower(seeder, 100 ether);
        _fundedBorrower(borrower, 100 ether);

        vm.prank(seeder);
        m.core.borrow(m.params, FLOOR, 0, seeder, seeder); // TBA = floor

        vm.prank(borrower);
        (uint256 assets,) = m.core.borrow(m.params, 1, 0, borrower, borrower); // dust, but market is populated
        assertEq(assets, 1, "a 1-wei borrow is allowed once the market is above the floor");
    }

    /// @dev The floor re-applies if a market is drained back into the dust regime.
    function test_floorReappliesAfterDrainToDust() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);

        vm.prank(borrower);
        (, uint256 shares) = m.core.borrow(m.params, FLOOR, 0, borrower, borrower);
        vm.prank(borrower);
        m.core.repay(m.params, 0, shares, borrower, ""); // full unwind -> TBA back below floor
        assertEq(m.core.market(m.id).totalBorrowAssets, 0, "drained below floor");

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(ILidoLendMarketController.BorrowBelowDustMarketMinimum.selector, FLOOR, 1)
        );
        m.core.borrow(m.params, 1, 0, borrower, borrower);
    }

    // ── the optimal attack (poison-cycle) is infeasible ──

    /// @dev The attacker's OPTIMAL borrow-share inflation, and why the floor makes it infeasible.
    ///
    ///      GOAL: drive `totalBorrowShares` to the `uint128` ceiling so every later borrow reverts, bricking the
    ///      market's borrow side. Payoff is only a temporary borrow DoS on a fresh market — no funds are at risk
    ///      (supply/withdraw/repay keep working) and the inflated position can be unwound, so this is pure grief.
    ///
    ///      ENGINE: a borrow of `a` assets mints `toSharesUp(a, TBA, TBS) = a*(TBS+VS)/(TBA+1)`, largest at the
    ///      SMALLEST `TBA`. The cheapest attack is the "poison-cycle": drive `TBA` to zero by repaying ONE share
    ///      at a time (each repay pays 1 wei and drops `TBA` by exactly 1, keeping `TBS` — the `toAssetsUp`
    ///      round-up burns 1 share to shed a whole wei), then `borrow(floor)` at `TBA = 0` mints ~`floor*TBS` in
    ///      one shot. One cycle costs ~`floor` transactions and multiplies `TBS` by ~`floor`.
    ///
    ///      WHY THE FLOOR WINS: `TBA`'s 1-wei granularity fixes the drive-to-zero at `floor` transactions per
    ///      cycle, and the floor forces the re-mint to be `>= floor` (no cheaper big mint exists). The ceiling is
    ///      then ~`floor * log_floor(2^128 / (floor*VS))` transactions away — with `floor = 1e5`, ~600k. No repay
    ///      chunk is cheaper (a bigger share repay still drops `TBA` by 1; a repay-by-assets burns `TBS` at the
    ///      fair rate and collapses the payload), so this is the true optimum. The test samples the drive-to-zero
    ///      on-chain, confirms the 1-wei step and preserved payload, and extrapolates the cost.
    function test_inflation_poisonCycle_optimalAttack_isInfeasible() public {
        Market storage m = _m();
        address attacker = _actor("attacker");
        _fundedBorrower(attacker, 100 ether);

        vm.prank(attacker);
        m.core.borrow(m.params, FLOOR, 0, attacker, attacker); // seed at the floor
        uint256 seedTBS = m.core.market(m.id).totalBorrowShares;

        // Poison-cycle drive-to-zero: each 1-share repay pays 1 wei and drops TBA by exactly 1, keeping TBS. A
        // full drive is `floor` iterations; sample it to confirm the per-tx step and the preserved payload.
        uint256 sample = 2000;
        for (uint256 i = 0; i < sample; ++i) {
            vm.prank(attacker);
            m.core.repay(m.params, 0, 1, attacker, "");
        }
        assertEq(m.core.market(m.id).totalBorrowAssets, FLOOR - sample, "each repay steps TBA down by exactly one wei");
        assertApproxEqRel(m.core.market(m.id).totalBorrowShares, seedTBS, 0.001e18, "TBS is preserved across the drain");

        // So reaching TBA=0 costs `floor` repays, after which borrow(floor) mints toSharesUp(floor, 0, TBS) =
        // floor*(TBS+VS) ~= floor*TBS: one cycle multiplies TBS by ~floor at ~floor transactions. Extrapolate to
        // the uint128 ceiling.
        uint256 mintAtZero = FLOOR * (seedTBS + VIRTUAL_SHARES); // toSharesUp(floor, 0, seedTBS)
        uint256 multiplier = (seedTBS + mintAtZero) / seedTBS; // ~floor
        uint256 cycles;
        uint256 acc = seedTBS;
        while (acc < type(uint128).max) {
            acc *= multiplier;
            ++cycles;
        }
        uint256 totalTxs = (FLOOR + 1) * cycles;
        console2.log("transactions per cycle       :", FLOOR + 1);
        console2.log("cycles to uint128 overflow   :", cycles);
        console2.log("total transactions (optimal) :", totalTxs);

        assertGt(totalTxs, 500_000, "the optimal (poison-cycle) attack needs >500k transactions");
    }

    /// @dev Fuzz: no bounded random chain of borrows and repays inflates the borrow-share counter. Reaching the
    ///      dust regime where inflation compounds needs ~floor operations per cycle, so a short chain cannot push
    ///      total borrow shares anywhere near overflow. Ports the off-chain adversarial search onto the live
    ///      contract; each op is attempted through the contract's own guards (reverts are skipped).
    function testFuzz_noShortChainInflatesShares(uint256 seed) public {
        Market storage m = _m();
        address attacker = _actor("attacker");
        _fundedBorrower(attacker, 100 ether);

        vm.prank(attacker);
        m.core.borrow(m.params, FLOOR, 0, attacker, attacker); // seed at the floor

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

    // ── repay carries no strand guard ──

    /// @dev A borrower can always fully close their own position, even with a co-borrower still outstanding.
    function test_repay_fullClose_withCoborrower_allowed() public {
        Market storage m = _m();
        address a = _actor("a");
        address b = _actor("b");
        _fundedBorrower(a, 100 ether);
        _fundedBorrower(b, 100 ether);

        vm.prank(a);
        (, uint256 aShares) = m.core.borrow(m.params, FLOOR, 0, a, a);
        vm.prank(b);
        m.core.borrow(m.params, FLOOR, 0, b, b);

        vm.prank(a);
        m.core.repay(m.params, 0, aShares, a, ""); // full close while b lingers
        assertEq(m.core.position(m.id, a).borrowShares, 0, "a fully closed its position");
        assertGt(m.core.market(m.id).totalBorrowShares, 0, "b still outstanding");
    }
}
