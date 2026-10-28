// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {MathLib, WAD} from "@lido-lend/src/libraries/MathLib.sol";
import {LIQUIDATION_CURSOR, MAX_LIQUIDATION_INCENTIVE_FACTOR} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {ExitStatus} from "../../src/types/ExitBookTypes.sol";
import {SettlementConfig, SettlementSlice} from "../../src/types/SettlementTypes.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";
import {ActivationModel} from "../setup/ActivationModel.sol";
import {Approvals} from "../setup/Approvals.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockPriceOracle} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";
import {SolvencyActions} from "./SolvencyActions.sol";
import {Random} from "./Random.sol";

/// @notice Solvency simulation. Many lenders, borrowers and keepers act at random for a month or a year on one
///         market while the price walks, interest accrues, governance pauses, freezes, caps and re-tunes, guardians
///         follow a fixed routine, tokens get donated and exit requests get filled. Then everyone leaves and the books
///         must balance: every number the protocol reports is checked against a total the test computed itself.
///         Solvency here means that every claim the core records is backed, by tokens it holds or by debt it is owed,
///         once bad debt is written off. Lenders still take that loss, since a write-off lowers every supplier's claim.
///         Each iteration draws the everyday move families by their odds, rare families fire once a run at a
///         scheduled time, and a slot of time passes after every move. Two ways to leave:
///         - repayment: borrowers repay, suppliers redeem, the market must empty exactly;
///         - forced exit: borrowers never repay, lenders leave through `fallbackExit` and are paid in collateral.
///         The market is the default config, which mirrors `script/config/markets/weth-wsteth.toml`. The suites
///         differ in decimals, price band and price walk, and each runs on the fixed and the adaptive IRM.
///         Long runs need `RUN_SOLVENCY_SIMULATION=true`.
/// @dev The clock moves inside a transaction, so the activation inflow decays between moves, and a reduction gives
///      back the inflow its borrower added since the transaction began. A transaction is one iteration on forge
///      1.8.x and the whole test on 1.7.x; `perCallTransactions` tells which, and the model closes them to match.
abstract contract SolvencySimulation is SolvencyActions {
    using MarketActions for Market;
    using Random for Random.Context;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    enum Unwind {
        Repayment,
        ForcedExit
    }

    uint256 internal constant SHORT_RUN = 30 days;
    uint256 internal constant LONG_RUN = 365 days;
    /// @dev Iterations between two checks of the running invariants.
    uint256 internal constant CHECK_EVERY = 20;
    /// @dev Bug detector, not a budget: the forced-exit loop ends at the first round that moves no share, so
    ///      reaching this many rounds means rounds keep moving shares without making progress.
    uint256 internal constant MAX_ROUNDS = 1000;
    /// @dev The borrow-share-rate ceiling market-controller.md "Borrow-share-rate transition guard" states as
    ///      `totalBorrowShares + 1e6 <= 1e7 * (totalBorrowAssets + 1)`.
    uint256 internal constant RATE_CEILING = 1e7;
    /// @dev An inflation cycle (`_strandingRepay`) borrows this many loan-asset units, and the ceiling admits this
    ///      many cycles before the next cycle's repay crosses it.
    uint256 internal constant INFLATION_BORROW = 1e5;
    uint256 internal constant INFLATION_CYCLES = 3;
    /// @dev Personal settlement target of the borrower whose allowance boundary is pinned, well under the LTV
    ///      the position is set up at, so the allowance is a positive cut short of the whole debt.
    uint256 internal constant TARGET_LTV = 0.1e18;
    /// @dev Seeds of runs that once failed, replayed by the `test_regressionSeed_*` tests. The driver has changed
    ///      since, so each seed now drives a different run.
    uint256 internal constant NO_WRITE_OFF_SEED =
        38193253766342865603630271185061325323286236833396905716926214211519342903248;
    uint256 internal constant SHARE_RESIDUE_SEED = 1023;

    bool internal longRun;
    uint256 internal rounds; // forced-exit rounds it took
    uint256 internal stalls; // forced exits that hit a predicted revert

    // ---
    // TESTS
    // ---

    function test_shortRun_repaymentUnwind() public {
        _setUpSimulation(_shortCounts());
        _run(SHORT_RUN, Unwind.Repayment);
    }

    function test_shortRun_forcedExitUnwind() public {
        _setUpSimulation(_shortCounts());
        _run(SHORT_RUN, Unwind.ForcedExit);
    }

    function test_longRun_repaymentUnwind() public {
        _requireLongRun();
        _setUpSimulation(_longCounts());
        _run(LONG_RUN, Unwind.Repayment);
    }

    function test_longRun_forcedExitUnwind() public {
        _requireLongRun();
        _setUpSimulation(_longCounts());
        _run(LONG_RUN, Unwind.ForcedExit);
    }

    /// @notice Regression: this seed once failed the WETH/wstETH crash suite with "weth/wsteth: no write-off", when the
    ///         scheduled crash drowned no leveraged borrower. Kept as a replay point.
    function test_regressionSeed_noWriteOff_repaymentUnwind() public {
        _useSeed(NO_WRITE_OFF_SEED);
        _setUpSimulation(_shortCounts());
        _run(SHORT_RUN, Unwind.Repayment);
    }

    /// @notice Regression: the same seed, unwound by forced exit instead of repayment.
    function test_regressionSeed_noWriteOff_forcedExitUnwind() public {
        _useSeed(NO_WRITE_OFF_SEED);
        _setUpSimulation(_shortCounts());
        _run(SHORT_RUN, Unwind.ForcedExit);
    }

    /// @notice Regression: this seed once failed a forced-exit unwind when an asset-anchored withdraw in
    ///         `_forcedDirectExit` stranded a direct lender's sub-unit share remainder. Kept as a replay point.
    function test_regressionSeed_shareResidue_forcedExitUnwind() public {
        _useSeed(SHARE_RESIDUE_SEED);
        _setUpSimulation(_shortCounts());
        _run(SHORT_RUN, Unwind.ForcedExit);
    }

    /// @dev A solvent liquidation takes at most collateral worth the debt and repays that value over LIF, so it
    ///      leaves a borrower underwater above LTV `1 / (2 - 1/LIF)`.
    ///      `_forcedLiquidations` must then write it off, or the exits would settle under a bad-debt root.
    function test_forcedLiquidations_nearInsolventBorrower_leavesNoBadDebt() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address l = lenders[0];
        address b = borrowers[0]; // instant activation: index 0 of every fourth borrower
        _mintLoan(l, 1000 * unit);
        m.vaultDeposit(l, 1000 * unit);
        _bookIn(l, 1000 * unit);
        _mintCollateral(b, 100 ether);
        borrower[b].collateralFunded += 100 ether;
        m.supplyCollateralInstant(b, b, 100 ether);
        borrower[b].loanBorrowed += _borrowRoom(b);
        m.borrow(b, borrower[b].loanBorrowed);
        m.distress(b, 0.97e18);
        assertTrue(_isUnhealthySolvent(b), "setup: borrower must be unhealthy but solvent");

        _forcedLiquidations();

        assertFalse(m.controller.hasBadDebt(), "forced liquidations left a bad-debt root");
        assertFalse(_isUnderwater(b), "forced liquidations left the borrower underwater");
    }

    /// @notice A supply of exactly `minActivationAmount` enters activating whole and, once matured, backs a borrow.
    ///         One unit under the threshold is dust and backs nothing; one unit over behaves like the threshold.
    /// @dev market-controller.md "Classifying a collateral supply" and "Borrower gating". Kills
    ///      `src/libs/CollateralActivationLib.sol:226` (`assetsWithDust < $.config.minActivationAmount`) and
    ///      `src/controllers/LidoLendMarketController.sol:612` (`collateral < _activation.config.minActivationAmount`).
    ///      Both are `<` against the same threshold, so all three lots are needed: the one under rules out `>` and
    ///      `>=`, the exact one `<=`, `>=` and `==`, and the one over `!=` and `>`, which the first two agree with.
    function test_activationFloor_exactThresholdActivates() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        assertEq(floor, cfg.minActivationAmount, "setup: the floor is the market's activation threshold");
        assertGe(floor - 1, cfg.minDepositAmount, "setup: one under the threshold still clears the deposit minimum");

        // `i % 4 == 1` and `i % 4 == 3` are the ordinary borrowers: no instant activation, no leverage loop.
        address atFloor = borrowers[1];
        address underFloor = borrowers[3];
        address overFloor = borrowers[5];
        _mintCollateral(atFloor, floor);
        _mintCollateral(underFloor, floor - 1);
        _mintCollateral(overFloor, floor + 1);

        m.supplyCollateral(atFloor, floor);
        ILidoLendMarketController.BorrowerPosition memory p = m.controller.positionOf(atFloor);
        assertEq(p.activating, floor, "exact threshold: the whole lot is activating");
        assertEq(p.dust, 0, "exact threshold: nothing is left as dust");

        m.supplyCollateral(underFloor, floor - 1);
        p = m.controller.positionOf(underFloor);
        assertEq(p.dust, floor - 1, "one under the threshold: the whole lot is dust");
        assertEq(p.activating, 0, "one under the threshold: nothing is activating");

        m.supplyCollateral(overFloor, floor + 1);
        p = m.controller.positionOf(overFloor);
        assertEq(p.activating, floor + 1, "one over the threshold: the whole lot is activating");
        assertEq(p.dust, 0, "one over the threshold: nothing is left as dust");

        address l = lenders[0];
        _mintLoan(l, 1000 * unit);
        m.vaultDeposit(l, 1000 * unit);
        // Lots mature lazily inside the next hook, so until the borrow, `positionOf` still reports them as activating.
        m.activateCollateral();
        p = m.controller.positionOf(atFloor);
        assertEq(uint256(m.core.position(m.id, atFloor).collateral), floor, "matured: the lot is the whole position");
        assertLe(p.unlockTime, block.timestamp, "matured: the activation delay has passed");
        assertGt(_capacity(floor), 0, "setup: threshold collateral must carry borrow capacity");

        m.borrow(atFloor, 1);
        assertEq(m.controller.positionOf(atFloor).active, floor, "the matured threshold lot is active in full");
        assertGt(m.core.position(m.id, atFloor).borrowShares, 0, "threshold collateral backed no borrow");

        m.borrow(overFloor, 1);
        assertEq(m.controller.positionOf(overFloor).active, floor + 1, "the matured over-threshold lot is active");
        assertGt(m.core.position(m.id, overFloor).borrowShares, 0, "over-threshold collateral backed no borrow");
    }

    /// @notice A non-root borrower's personal settlement allowance is exact to the share: a cut one share above
    ///         it is rejected, a cut of exactly it settles, and so does a cut under it.
    /// @dev lender-settlement.md "Personal settlement target" and "Controller execution rules". Kills
    ///      `src/controllers/LidoLendMarketController.sol:560` (`cutShares > personalAllowedShares`): the cut above
    ///      rules out `<`, `<=` and `==`, the cut at the allowance `>=`, and the cut under it `!=`.
    function test_personalAllowance_oneShareAboveReverts() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address d = directLenders[0];
        _mintLoan(d, 1000 * unit);
        m.coreSupply(d, 1000 * unit);

        // The queue's risk key is borrow shares per collateral unit, so the root is the one borrowing the largest
        // fraction of its room. `under` is a leveraged borrower, which setup already gave collateral.
        address riskier = borrowers[0];
        address exact = borrowers[4];
        address under = borrowers[2];
        _mintCollateral(riskier, 100 ether);
        _mintCollateral(exact, 100 ether);
        m.supplyCollateralInstant(riskier, riskier, 100 ether);
        m.supplyCollateralInstant(exact, exact, 100 ether);
        m.borrow(exact, _borrowRoom(exact) / 4);
        m.borrow(under, _borrowRoom(under) / 4);
        m.borrow(riskier, _borrowRoom(riskier) / 2);
        m.setSettlementLtv(exact, TARGET_LTV);
        m.setSettlementLtv(under, TARGET_LTV);
        borrower[exact].settlementLtv = TARGET_LTV;
        borrower[under].settlementLtv = TARGET_LTV;

        (address root,) = m.controller.nextSettlementBorrower(0);
        assertEq(root, riskier, "setup: the settled borrowers must not be the queue root");
        assertFalse(_isUnderwater(root), "setup: the queue root must not be bad debt");

        uint256 allowed = _personalAllowedShares(exact);
        assertGt(allowed, 0, "setup: the target opted into a positive personal allowance");

        vm.prank(d);
        vm.expectRevert(ILidoLendMarketController.SettlementExceedsAllowed.selector);
        m.core.settle(m.params, allowed + 1, d, exact, d);

        m.coreSettle(d, exact, allowed, d);

        // The second target is settled under its own allowance, against the totals the first cut left behind.
        uint256 allowedUnder = _personalAllowedShares(under);
        assertGt(allowedUnder, 1, "setup: the second target's allowance must leave room under it");
        m.coreSettle(d, under, allowedUnder - 1, d);
    }

    /// @notice The borrow-share-rate ceiling stops the near-full repay that would cross it, and lets every repay
    ///         under it through.
    /// @dev market-controller.md "Borrow-share-rate transition guard": a repay may not move the market from at or
    ///      below `RATE_CEILING` to above it. Kills `src/controllers/LidoLendMarketController.sol:600` (`if
    ///      (_isBorrowShareRateExceeded(postAssets, postShares)) revert BorrowShareRateExceeded();` mutated so the
    ///      condition never holds).
    function test_borrowShareRate_atCeilingReverts() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        assertEq(m.controller.MAX_BORROW_SHARE_RATE(), RATE_CEILING, "setup: the deployed ceiling is the spec's");

        address l = lenders[0];
        _mintLoan(l, 1000 * unit);
        m.vaultDeposit(l, 1000 * unit);

        address b = borrowers[0];
        _mintCollateral(b, 100 ether);
        m.supplyCollateralInstant(b, b, 100 ether);
        _mintLoan(b, 1000 * unit);

        // From zero, the cycles leave 999 999, 2 999 997 and 6 999 993 shares, within the ceiling's 9e6 at zero
        // assets; a fourth would leave 14 999 985.
        for (uint256 c; c < INFLATION_CYCLES; ++c) {
            m.repay(b, _strandingRepay(b));
        }

        uint256 crossing = _strandingRepay(b);
        MorphoMarket memory mk = m.core.market(m.id);
        assertTrue(
            _rateBlocked(
                mk.totalBorrowAssets,
                mk.totalBorrowShares,
                crossing.toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares),
                crossing
            ),
            "setup: the near-full repay must cross the ceiling from below"
        );

        vm.prank(b);
        vm.expectRevert(ILidoLendMarketController.BorrowShareRateExceeded.selector);
        m.core.repay(m.params, 0, crossing, b, "");
    }

    /// @notice A cut whose debt buys no whole collateral unit is reported as no cut at all; one unit more of debt
    ///         makes the cut available.
    /// @dev lender-settlement.md "Seizure floor": a cut that seizes nothing is an unavailable candidate, not a quote
    ///      the core would reject. Kills `src/libs/SettlementQueueLib.sol:213` (`_seizedCollateral(marketView,
    ///      canceledShares) == 0`): the sub-unit lot rules out `<`, the one-unit lot `>=`, and both `!=` and `>`.
    ///      `<=` equals `==` on `uint256` and is unkillable.
    ///      Line 268, the `Math.mulDiv` the floor rounds down in, has no mutant: forge has no operator for a bare
    ///      `return f(a, b, c);`. The price is raised to two loan-asset units per collateral unit, which reaches the
    ///      boundary on any price band and only makes the position healthier.
    function test_seizureFloor_subUnitCutIsUnavailable() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address l = lenders[0];
        _mintLoan(l, 1000 * unit);
        m.vaultDeposit(l, 1000 * unit);

        address b = borrowers[0];
        _mintCollateral(b, 100 ether);
        m.supplyCollateralInstant(b, b, 100 ether);
        m.borrow(b, _borrowRoom(b) / 2);

        MockPriceOracle(address(m.oracle)).setPrice(2 * ORACLE_SCALE);
        assertEq(Math.mulDiv(1, ORACLE_SCALE, _price()), 0, "setup: one loan asset buys no whole collateral unit");
        assertEq(Math.mulDiv(2, ORACLE_SCALE, _price()), 1, "setup: two loan assets buy exactly one unit");

        // A flat root policy, so the quote is exactly the absolute term and nothing promotes it.
        m.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 0, sliceFloorAssets: 1, fullCutBelowCollateral: 0, ltvStepBps: 0})
        );
        (address root, SettlementSlice memory slice) = m.controller.nextSettlementBorrower(0);
        assertEq(root, b, "setup: the only debtor is the queue root");
        assertEq(slice.borrowShares, 0, "a cut that seizes nothing must be unavailable");

        m.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 0, sliceFloorAssets: 2, fullCutBelowCollateral: 0, ltvStepBps: 0})
        );
        (, slice) = m.controller.nextSettlementBorrower(0);
        assertGt(slice.borrowShares, 0, "a cut that seizes one whole unit must be available");
    }

    /// @notice A keeper authorized by a banned borrower cannot borrow on its behalf, even though neither the
    ///         caller nor the receiver is banned.
    /// @dev market-controller.md "Borrower gating": a borrow fails when the caller, the debt owner or the loan
    ///      receiver is banned. Kills `src/controllers/LidoLendMarketController.sol:488` (`if (opinion.banned)
    ///      revert AddressBanned();` mutated so the condition never holds).
    function test_borrowOnBehalf_bannedOwnerReverts() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address l = lenders[0];
        _mintLoan(l, 1000 * unit);
        m.vaultDeposit(l, 1000 * unit);

        address b = borrowers[0];
        address k = keepers[0];
        assertTrue(protocol.core.isAuthorized(b, k), "setup: the keeper may borrow on the owner's behalf");
        _mintCollateral(b, 100 ether);
        m.supplyCollateralInstant(b, b, 100 ether);

        address[] memory guardians = new address[](2);
        guardians[0] = guardian2;
        guardians[1] = address(this);
        m.banVia(guardians, b);
        bannedModel[b] = true;

        assertTrue(_isBanned(b), "setup: the debt owner is banned");
        assertFalse(_isBanned(k), "setup: the caller and receiver are not banned");
        assertGt(_borrowRoom(b), 0, "setup: the owner's active collateral still carries room");

        vm.prank(k);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        m.core.borrow(m.params, 1, 0, b, k);
    }

    /// @notice A repay is a market hook like any other, so a paused controller blocks it.
    /// @dev market-controller.md "Freeze and pause". Kills `src/controllers/LidoLendMarketController.sol:167`
    ///      (`_checkResumed();` deleted or made conditional).
    function test_repayWhilePaused_reverts() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address l = lenders[0];
        _mintLoan(l, 1000 * unit);
        m.vaultDeposit(l, 1000 * unit);

        address b = borrowers[0];
        _mintCollateral(b, 100 ether);
        m.supplyCollateralInstant(b, b, 100 ether);
        uint256 shares = m.borrow(b, _borrowRoom(b) / 2);
        Approvals.approve(address(m.loanToken), b, address(m.core), type(uint256).max);

        _pauseFor(2 hours);
        assertTrue(_paused(), "setup: the controller is paused");
        assertGt(shares, 0, "setup: the borrower carries debt to repay");

        vm.prank(b);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.repay(m.params, 0, shares, b, "");
    }

    /// @notice A lender that loses value off the books and leaves before a write-off fails the lender check. The
    ///         write-off costs more than that loss, so a bound on the loss of the whole run would let it through.
    /// @dev A share transfer the ledger never books stands in for any value moved between lenders.
    function test_lenderCheck_unbookedLossBeforeWriteOff_fails() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        address early = lenders[0];
        address late = lenders[1];
        _depositBy(early, 500 * unit);
        _depositBy(late, 500 * unit);

        uint256 unbooked = m.vault.balanceOf(early) / 10;
        vm.prank(early);
        m.vault.transfer(late, unbooked);
        _bookOut(early, m.vaultRedeem(early, m.vault.balanceOf(early)));
        lender[early].ops++;

        address b = borrowers[0]; // instant activation: index 0 of every fourth borrower
        _mintCollateral(b, 1000 ether);
        borrower[b].collateralFunded += 1000 ether;
        m.supplyCollateralInstant(b, b, 1000 ether);
        borrower[b].loanBorrowed += _borrowRoom(b);
        m.borrow(b, borrower[b].loanBorrowed);
        m.distress(b, 1.25e18);
        uint256 lateBefore = m.vault.previewRedeem(m.vault.balanceOf(late));
        _writeOff(keepers[0], b);
        assertLt(
            m.vault.previewRedeem(m.vault.balanceOf(late)) * 10,
            lateBefore * 9,
            "setup: the write-off must cost more than the unbooked loss"
        );

        try this.checkLenders() {
            assertTrue(false, "the lender check missed the unbooked loss");
        } catch (bytes memory failure) {
            // A failed assertion reverts with forge's `CheatcodeError(string)`: the selector, then the message.
            assertEq(bytes4(failure), bytes4(keccak256("CheatcodeError(string)")), "the lender check did not fail");
            bytes memory encoded = new bytes(failure.length - 4);
            for (uint256 i; i < encoded.length; ++i) {
                encoded[i] = failure[i + 4];
            }
            assertEq(
                vm.indexOf(abi.decode(encoded, (string)), "lender: below its flows"),
                0,
                "the lender check failed for another reason"
            );
        }
    }

    /// @notice Audit FZ-18: two borrowers tie on the rounded risk key. The root is solvent at exactly its debt, and
    ///         the tied borrower is short by about one key unit of debt. The queue check accepts that shortfall.
    /// @dev lender-settlement.md "A rounded root check can miss an insolvent borrower". With 1e25 collateral, one key
    ///      unit is 1e7 borrow shares: about 10 loan units at the opening rate of 1e-6 asset per share.
    function test_tiedRiskKey_shortfallWithinOneKeyUnit() public {
        _setUpSimulation(_shortCounts());
        Market storage m = _m();
        _mintLoan(lenders[0], 1000 * unit);
        m.vaultDeposit(lenders[0], 1000 * unit);
        assertEq(m.core.market(m.id).totalBorrowShares, 0, "setup: no debt before the tie");

        uint256 collateral = 1e25;
        uint256 rootShares = 1000 * 1e7;
        uint256 tiedShares = rootShares + 1e7 - 1;
        address root = borrowers[0]; // instant activation: index 0 of every fourth borrower
        address tied = borrowers[4];
        _mintCollateral(root, collateral);
        _mintCollateral(tied, collateral);
        m.supplyCollateralInstant(root, root, collateral);
        m.supplyCollateralInstant(tied, tied, collateral);
        vm.prank(root);
        m.core.borrow(m.params, 0, rootShares, root, root);
        vm.prank(tied);
        m.core.borrow(m.params, 0, tiedShares, tied, tied);
        assertEq(m.core.position(m.id, tied).collateral, collateral, "setup: the tied borrower holds only this lot");

        MorphoMarket memory mk = m.core.market(m.id);
        uint256 assets = uint256(mk.totalBorrowAssets) + SharesMathLib.VIRTUAL_ASSETS;
        uint256 shares = uint256(mk.totalBorrowShares) + SharesMathLib.VIRTUAL_SHARES;
        uint256 rootDebt = Math.mulDiv(rootShares, assets, shares, Math.Rounding.Ceil);
        // The root's collateral is worth exactly its debt, so the root sits on the solvent side of the gate.
        MockPriceOracle(address(m.oracle)).setPrice(rootDebt * ORACLE_SCALE / collateral);
        assertEq(Math.mulDiv(collateral, _price(), ORACLE_SCALE), rootDebt, "setup: root value != root debt");
        assertGt(
            Math.mulDiv(tiedShares, assets, shares, Math.Rounding.Ceil), rootDebt, "setup: tied borrower not short"
        );

        (address[] memory queued, uint256[] memory keys) = m.controller.settlementBorrowers(0, 2);
        assertEq(queued[0], root, "setup: the first borrower is not the root");
        assertEq(keys[0], keys[1], "setup: the keys do not tie");
        assertFalse(m.controller.hasBadDebt(), "setup: the root carries bad debt");
        _checkQueueRoot();
    }

    /// @dev `_checkLenders` as a call of its own, so a test can catch its failure.
    function checkLenders() external view {
        _checkLenders();
    }

    /// @dev One near-full-repay inflation cycle from `s` borrow shares at zero borrow assets: borrows
    ///      `INFLATION_BORROW` and returns the shares whose repay leaves `2 s + 1e6 - 1` shares at zero assets,
    ///      about doubling the virtual share total. The caller repays them or expects the ceiling to block it.
    function _strandingRepay(address b) internal returns (uint256) {
        Market storage m = _m();
        uint256 sharesBefore = m.core.market(m.id).totalBorrowShares;
        uint256 minted = m.borrow(b, INFLATION_BORROW);
        return minted - (sharesBefore + SharesMathLib.VIRTUAL_SHARES - 1);
    }

    function _shortCounts() internal pure returns (Counts memory) {
        return Counts({lenders: 6, directLenders: 2, borrowers: 8, keepers: 2});
    }

    function _longCounts() internal pure returns (Counts memory) {
        return Counts({lenders: 32, directLenders: 6, borrowers: 48, keepers: 4});
    }

    function _requireLongRun() internal {
        if (!vm.envOr("RUN_SOLVENCY_SIMULATION", false)) vm.skip(true, "set RUN_SOLVENCY_SIMULATION=true");
    }

    /// @dev What the market's price model implies for the run, asserted once it has unwound.
    function _assertPriceModelConsequences() internal view virtual {}

    // ---
    // THE RUN
    // ---

    function _run(uint256 duration, Unwind mode) internal {
        _logHeader(duration, mode);
        longRun = duration >= LONG_RUN;
        runStart = block.timestamp;
        runDuration = duration;
        uint256 end = runStart + duration;
        _scheduleEvents(runStart, end);
        uint256 iterations;
        while (block.timestamp < end) this.iterate(++iterations);
        _checkRunningInvariants();

        if (mode == Unwind.Repayment) _unwindByRepayment();
        else _unwindByForcedExit();

        _checkRunningInvariants();
        if (mode == Unwind.Repayment) _checkEndStateRepayment();
        else _checkEndStateForced();
        _checkLenders();
        _checkBorrowers();
        _assertPriceModelConsequences();
        _assertCoverage();
        _logStats(iterations);
    }

    /// @dev Coverage floors. Every run must have exercised the everyday moves, fired every scheduled rare family
    ///      and blocked something; a year must also have exercised the odds-based families too rare to schedule.
    function _assertCoverage() internal view {
        for (uint256 i; i < schedule.length; ++i) {
            assertTrue(schedule[i].fired, string.concat("schedule: ", _name(schedule[i].action), " never came due"));
        }
        // A floor on an everyday family holds when `p*E >= 0.062`, so that `(1 - p*E)^218 < 1e-6` over a short run of
        // at least 218 iterations; the shortest of 320 measured runs had 240. `p` is the family's odds per iteration,
        // `E` the share of its draws that end the way the floor counts.
        //   Deposit            p = 0.25, E >= 0.3: tokens are minted for the lender, so only the pause and a cap
        //     block it, each scheduled once with a closer.
        //   Withdraw           p = 0.20, E >= 0.5: a holder exists early, and a draw fails only while the vault can
        //     pay out nothing: the pause, or a fully lent market, which Borrow's cap at the free liquidity keeps brief.
        //   SupplyCollateral   p = 0.30, E >= 0.5: the 6 unleveraged of 8 borrowers are always eligible, and only
        //     the pause, the 1-in-50 sub-minimum draws and sub-floor lots that leave dust unresolved are turned away.
        //   Borrow             p = 0.30, E >= 0.3: room follows the collateral SupplyCollateral keeps adding.
        //   PriceStep          p = 0.20, E = 1: the oracle always moves.
        // Two floors sit under the bound and rest on measurement, since the state they need persists once reached
        // while the bound treats draws as independent:
        //   RepayPartial       p = 0.15, E >= 0.36: Borrow at twice these odds keeps a third to a half of the
        //     unleveraged borrowers in debt. At least 13 moves in each of 320 runs.
        //   WithdrawCollateral p = 0.10, E >= 0.60: the 3-in-10 lock and all-or-nothing probes cap `E` at 0.7, and
        //     nearly every borrower holds collateral its debt does not need. At least 9 moves in each of 320 runs.
        // FallbackExit (p = 0.05) cannot reach 0.062 and FillExitRequest (p = 0.10) would need E >= 0.62, so their
        // scenarios carry the floor and count only successes. A scenario waits past its schedule time for a slot
        // where its move goes through. Argued: the market pause lasts at most 12 slots and the book pause at most
        // 68, once a run each, so `_scheduleEvents` ends the fallback exit's window 12 slots early and the fill's
        // 80. Not argued: the liquidity each also needs (`_fallbackExitReady`, `_fillExitRequestReady`), which
        // everyday moves drive. The longest measured wait was 44 slots.
        _assertMoved(Action.Deposit);
        _assertMoved(Action.Withdraw);
        _assertMoved(Action.SupplyCollateral);
        _assertMoved(Action.Borrow);
        _assertMoved(Action.RepayPartial);
        _assertMoved(Action.WithdrawCollateral);
        _assertMoved(Action.PriceStep);
        _assertMoved(Action.FallbackExitScenario);
        _assertMoved(Action.FillExitRequestScenario);
        // `Settle` and `CoreSettle` carry no floor of their own: their scenarios must each settle once a run. A
        // settlement scenario brings its own funding, debt and personal target, so it waits only on what its steps
        // cannot lift. Argued: the pause (12 slots), the freeze and a cap (68 each with their closers), 148 slots
        // back to back; a ban, which never delays it, since guardians ban only ordinary borrowers and
        // `_canBeSettleTarget` reads the ban only for instant ones; and a bad-debt root. That root closes once
        // `LiquidateBadDebt` (p = 0.30, blocked only by the pause) has written off every underwater borrower, so it
        // outlasts `K = 5 * borrowers + 44` iterations with probability at most `P(Bin(K - 4, 0.3) < borrowers)`:
        // 6.2e-6 a month, 1.8e-6 a year. So `_scheduleEvents` ends both windows 148 slots plus `K` iterations of
        // 3.3 slots early. Not argued: a bad-debt root the walk's ordinary 2% steps open, and the borrow-share
        // ceiling, which the share rate sits ten times under. The longest measured waits were 38 slots on a month
        // and 110 on a year.
        _assertMoved(Action.SettleScenario);
        _assertMoved(Action.CoreSettleScenario);
        // The one floor on a revert: `_liquidate` stands any borrower in when none is liquidatable, and the core
        // rejects a healthy one before the hook. This family and `LiquidateBadDebt` clear unhealthy positions as
        // they appear, so between price moves there is usually nothing to liquidate: p = 0.20, E >= 0.35. The
        // success carries no floor here: on a steady price only accrual tips a leveraged borrower drawn to its room,
        // and a month can miss that (1 of 8 measured seeds on WETH/wstETH). The crash suite floors the write-off on
        // both lengths and the solvent liquidation on a year, and every suite, so each loan scale, liquidates in
        // `test_forcedLiquidations_nearInsolventBorrower_leavesNoBadDebt`.
        assertGt(predicted[Action.Liquidate], 0, "coverage: no predicted Liquidate");
        // Implied by the Liquidate floor, and kept as the statement that holds whatever the odds do. No other
        // revert family carries a floor: `Borrow` needs E >= 0.21 but rarely lacks room, `Settle` and
        // `PlaceExitRequest` (p = 0.05) cannot reach 0.062, `FillExitRequest` would need E >= 0.62, and
        // `LiquidateBadDebt` would only repeat the Liquidate floor.
        uint256 blocked;
        for (uint256 a; a <= uint256(type(Action).max); ++a) {
            blocked += predicted[Action(a)];
        }
        assertGt(blocked, 0, "coverage: no predicted revert");

        assertGt(g.pauses, 0, "coverage: no pause");
        assertEq(g.bans, longRun ? 37 : 3, "coverage: bans != one per incident");
        // Implied by the schedule, since `_setSupplyCap` always sets a live cap, and kept as the statement the
        // deposit and core-supply floors rest on: a run that never capped the market never tested the cap.
        assertGt(g.caps, 0, "coverage: no supply cap set");
        // The scheduled third-party supply may land in the pause or over the cap and take a predicted revert.
        assertGt(
            count[Action.ThirdPartySupply] + predicted[Action.ThirdPartySupply],
            0,
            "coverage: third-party supply never exercised"
        );
        assertGt(g.donatedLoanToVault, 0, "coverage: no loan-to-vault gift");
        assertGt(g.donatedLoanToCore, 0, "coverage: no loan-to-core gift");
        assertGt(g.donatedCollateralToCore, 0, "coverage: no collateral-to-core gift");
        _assertMoved(Action.Freeze);
        _assertMoved(Action.Unfreeze);
        _assertMoved(Action.SetSettlementConfig);
        _assertMoved(Action.SetActivationConfig);
        _assertMoved(Action.PauseBook);
        _assertMoved(Action.ResumeBook);
        _assertMoved(Action.Resume);
        _assertMoved(Action.RemoveSupplyCap);
        if (!longRun) return;

        // A year runs at least 2 800 iterations (the shortest of 80 measured years ran 3 140), so a floor holds when
        // `p*E >= 0.004934`, which makes `(1 - p*E)^2800 < 1e-6`. With 32 lenders, 6 direct lenders and 48 borrowers,
        // an eligible actor, once one exists, stays eligible for the rest of the run, so `E` is close to 1 for each
        // floor below:
        //   CoreSettleNonRoot  p = 0.02, needs E >= 0.25: direct lenders supply at 0.05, and a non-root borrower
        //     with debt and collateral exists whenever two borrow.
        //   TransferShares     p = 0.03, needs E >= 0.17: a holder and another lender exist once a few deposit.
        //   predicted[WithdrawCollateral] p = 0.10 * 0.3, needs E >= 0.17: the 0.3 is the lock or all-or-nothing
        //     probe, reached whenever the drawn borrower holds inactive collateral.
        // Not floored: the `FillExitRequest` and `CoreSettleNonRoot` reverts, whose several gates give no fixed `p`.
        _assertMoved(Action.CoreSettleNonRoot);
        _assertMoved(Action.TransferShares);
        assertGt(predicted[Action.WithdrawCollateral], 0, "coverage: no blocked collateral withdrawal");
    }

    function _assertMoved(Action a) internal view {
        assertGt(count[a], 0, string.concat("coverage: no ", _name(a)));
    }

    /// @dev One iteration. The schedule is re-checked after every slot, so an entry fires in the slot it comes due.
    ///      An external self-call, so memory does not pile up over a year; on forge 1.8.x it is its own transaction.
    function iterate(uint256 iteration) external {
        require(msg.sender == address(this), "iterate: self only");
        if (perCallTransactions) ActivationModel.beginTransaction(activation, borrowers);
        _fireDue();
        bool acted;
        for (uint256 a; a <= uint256(type(Action).max); ++a) {
            if (!random.chance(bps[Action(a)])) continue;
            _execute(Action(a));
            _advanceSlot();
            _fireDue();
            acted = true;
        }
        if (!acted) _advanceSlot();
        if (iteration % CHECK_EVERY == 0) _checkRunningInvariants();
    }

    // ---
    // RUNNING INVARIANTS
    // ---

    function _checkRunningInvariants() internal view {
        _checkBooks();
        _checkShares();
        _checkTokens();
        _checkBorrowerBuckets();
        _checkQueueRoot();
        _checkPauseLimits();
    }

    /// @dev The core's books against the model. The vault is worth exactly its core position less the gifted shares,
    ///      which back no vault share (lender-settlement.md "Vault accounting boundary").
    function _checkBooks() internal view {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        assertGe(mk.totalSupplyAssets, mk.totalBorrowAssets, "books: supply covers borrow");
        (uint256 loanIn, uint256 loanOut, uint256 canceled) = _supplierTotals();
        assertEq(
            uint256(mk.totalSupplyAssets),
            loanIn + g.thirdPartyAssets + g.interest - g.badDebt - loanOut - canceled,
            "books: supply total != deposits + gifts + interest - withdrawals - bad debt - settled debt"
        );
        MorphoMarket memory accrued = m.accruedMarket();
        uint256 managed = m.core.position(m.id, address(m.vault)).supplyShares - g.thirdPartyShares;
        assertEq(
            m.vault.totalAssets(),
            managed.toAssetsDown(accrued.totalSupplyAssets, accrued.totalSupplyShares),
            "books: vault totalAssets != managed shares"
        );
    }

    /// @dev Core supply shares and vault shares are partitioned exactly among the holders the test tracks.
    function _checkShares() internal view {
        Market storage m = _m();
        uint256 vaultShares = m.core.position(m.id, address(m.vault)).supplyShares;
        uint256 others = m.core.position(m.id, feeRecipient).supplyShares;
        for (uint256 i; i < directLenders.length; ++i) {
            others += m.core.position(m.id, directLenders[i]).supplyShares;
        }
        assertEq(vaultShares + others, m.core.market(m.id).totalSupplyShares, "shares: core supply partition");
        assertEq(vaultShares - m.vault.managedSupplyShares(), g.thirdPartyShares, "shares: vault manages all but gifts");

        uint256 held;
        for (uint256 i; i < lenders.length; ++i) {
            held += m.vault.balanceOf(lenders[i]);
        }
        assertEq(held, m.vault.totalSupply(), "shares: vault share partition");
        assertEq(m.vault.balanceOf(address(book)), 0, "shares: book holds vault shares");
    }

    /// @dev Every minted token is in a wallet, the core or the vault, and the book holds nothing at rest. The core
    ///      holds at least the idle supply plus the gifts; rounding may leave a few extra units there.
    function _checkTokens() internal view {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 coreLoan = m.loanToken.balanceOf(address(m.core));
        uint256 coreCollateral = m.collateralToken.balanceOf(address(m.core));
        assertGe(
            coreLoan,
            mk.totalSupplyAssets - mk.totalBorrowAssets + g.donatedLoanToCore,
            "tokens: idle supply not backed"
        );
        assertEq(m.loanToken.balanceOf(address(m.vault)), g.donatedLoanToVault, "tokens: vault loan != gifts");
        assertEq(m.collateralToken.balanceOf(address(m.vault)), 0, "tokens: vault holds collateral");
        assertEq(m.loanToken.balanceOf(address(book)), 0, "tokens: book holds loan");

        (uint256 loanHeld, uint256 collateralHeld, uint256 positions) = _walletTotals();
        assertEq(loanHeld + coreLoan + g.donatedLoanToVault, g.loanMinted, "tokens: loan conservation");
        assertEq(collateralHeld + coreCollateral, g.collateralMinted, "tokens: collateral conservation");
        assertEq(positions + g.donatedCollateralToCore, coreCollateral, "tokens: collateral positions != core balance");
        assertEq(g.bookReceiver + g.bookReward + g.bookService, g.bookFilled, "tokens: book fills do not split exactly");
    }

    /// @dev Per borrower: the controller's activation state is exactly the model's, and a position with debt and no
    ///      forced reduction since its debt last cleared keeps at least the floor of active collateral.
    function _checkBorrowerBuckets() internal view {
        Market storage m = _m();
        for (uint256 i; i < borrowers.length; ++i) {
            address b = borrowers[i];
            _assertActivation(b);
            if (m.core.position(m.id, b).borrowShares > 0 && !borrower[b].forced) {
                assertGe(m.controller.positionOf(b).active, floor, "buckets: debt on active collateral below the floor");
            }
        }
    }

    /// @dev The queue holds exactly the borrowers with debt and collateral; its root and bad-debt flag match the model.
    ///      Each member carries the spec key of its current position, and no child key exceeds its parent's
    ///      (lender-settlement.md "Risk queue and bad-debt gate"; heap index 0 is the root).
    function _checkQueueRoot() internal view {
        Market storage m = _m();
        (,, uint256 tracked) = _modelRoot();
        uint256 size = m.controller.settlementBorrowersCount();
        assertEq(size, tracked, "queue: size != borrowers with debt and collateral");
        (address root,) = m.controller.nextSettlementBorrower(0);
        _assertRoot(root);
        assertEq(m.controller.hasBadDebt(), _rootBadDebt(), "queue: bad-debt flag != model");

        (address[] memory queued, uint256[] memory keys) = m.controller.settlementBorrowers(0, size);
        assertEq(queued.length, size, "queue: window != size");
        // With the size equal to `tracked`, one entry per tracked borrower leaves no room for anyone else.
        for (uint256 i; i < borrowers.length; ++i) {
            Position memory p = m.core.position(m.id, borrowers[i]);
            uint256 entries;
            for (uint256 j; j < size; ++j) {
                if (queued[j] == borrowers[i]) ++entries;
            }
            assertEq(entries, p.borrowShares > 0 && p.collateral > 0 ? 1 : 0, "queue: member iff debt and collateral");
        }
        for (uint256 i; i < size; ++i) {
            Position memory p = m.core.position(m.id, queued[i]);
            assertEq(
                keys[i], Math.mulDiv(p.borrowShares, WAD, p.collateral), "queue: key != shares * 1e18 / collateral"
            );
            if (i > 0) assertGe(keys[(i - 1) / 2], keys[i], "queue: child key above its parent");
        }
        if (!m.controller.hasBadDebt()) _checkSolventRootShortfall(queued);
    }

    /// @dev Audit FZ-18: under a solvent root, a member's debt exceeds its collateral value by at most one key unit of
    ///      debt plus two units. A member's key is at most the root's, and each key rounds down by less than one. So
    ///      the member's LTV exceeds the root's by less than one key unit. The debt ceiling and the value floor add
    ///      one unit each. The bad-debt gate reads accrued totals, so this check does too.
    function _checkSolventRootShortfall(address[] memory queued) internal view {
        Market storage m = _m();
        MorphoMarket memory mk = m.accruedMarket();
        uint256 assets = uint256(mk.totalBorrowAssets) + SharesMathLib.VIRTUAL_ASSETS;
        uint256 shares = uint256(mk.totalBorrowShares) + SharesMathLib.VIRTUAL_SHARES;
        for (uint256 i; i < queued.length; ++i) {
            Position memory p = m.core.position(m.id, queued[i]);
            uint256 debt = Math.mulDiv(p.borrowShares, assets, shares, Math.Rounding.Ceil);
            uint256 value = Math.mulDiv(p.collateral, _price(), ORACLE_SCALE);
            uint256 keyUnit = Math.mulDiv(p.collateral, assets, shares * WAD, Math.Rounding.Ceil);
            assertLe(Math.saturatingSub(debt, value), keyUnit + 2, "queue: solvent root hides a shortfall over one key");
        }
    }

    /// @dev While paused the vault accepts nothing and lets nothing out.
    function _checkPauseLimits() internal view {
        if (!_paused()) return;
        Market storage m = _m();
        // Read from the vault on purpose: its own limits are what this asserts.
        assertEq(m.vault.maxDeposit(lenders[0]), 0, "paused: maxDeposit");
        assertEq(m.vault.maxWithdraw(lenders[0]), 0, "paused: maxWithdraw");
    }

    // ---
    // UNWIND
    // ---

    /// @dev Governance lifts whatever blocks exits: the pause, the freeze, the cap and the activating lock (zero
    ///      disables it, market-controller.md "Configuration changes"), and every open exit request is cancelled. No
    ///      ban is left to lift: every guardian incident ends with its unban inside the run. The deployed settlement
    ///      policy comes back too: a re-tuned one can cut a fraction of a percent of the debt per slice, which takes
    ///      the forced unwind hundreds of rounds. Then the paused span accrues.
    function _unwindPrelude() internal {
        Market storage m = _m();
        // On forge 1.8.x every unwind call is a transaction of its own, so none inherits an inflow contribution.
        if (perCallTransactions) ActivationModel.beginTransaction(activation, borrowers);
        if (_paused()) {
            m.resume();
            pauseUntil = block.timestamp;
        }
        if (m.controller.isFrozen()) m.unfreeze();
        for (uint256 i; i < borrowers.length; ++i) {
            assertFalse(m.guardianSignals.isBanned(m.id, borrowers[i]), "unwind: a guardian ban outlived its incident");
        }
        m.setSupplyCap(0);
        m.setSettlementConfig(m.config.settlementConfig);
        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        if (cfg.activatingLockDuration != 0) {
            cfg.activatingLockDuration = 0;
            m.setActivationConfig(cfg);
        }
        for (uint256 id = 1; id <= book.lastRequestId(); ++id) {
            if (book.getExitRequest(id).status == ExitStatus.Open) _cancel(id);
        }
        _advanceSlot();
    }

    function _unwindByRepayment() internal {
        _unwindPrelude();
        Market storage m = _m();
        for (uint256 i; i < borrowers.length; ++i) {
            address b = borrowers[i];
            uint256 bs = m.core.position(m.id, b).borrowShares;
            if (bs > 0) {
                uint256 owed = m.repayAssets(bs);
                borrower[b].loanFunded += _ensureLoan(b, owed);
                MorphoMarket memory mk = m.core.market(m.id);
                assertFalse(
                    _rateBlocked(mk.totalBorrowAssets, mk.totalBorrowShares, owed, bs),
                    "unwind: full repay blocked by the share ceiling"
                );
                m.repay(b, bs);
                borrower[b].loanRepaid += owed;
                _syncForced(b);
            }
            uint256 coll = m.core.position(m.id, b).collateral;
            if (coll > 0) _withdrawAndBook(b, coll);
        }
        for (uint256 i; i < lenders.length; ++i) {
            address l = lenders[i];
            uint256 bal = m.vault.balanceOf(l);
            if (bal == 0) continue;
            _bookOut(l, m.vaultRedeem(l, bal));
            lender[l].ops++;
        }
        address[] memory direct = _directAndFee();
        for (uint256 i; i < direct.length; ++i) {
            uint256 shares = m.core.position(m.id, direct[i]).supplyShares;
            if (shares == 0) continue;
            _bookOut(direct[i], m.coreWithdraw(direct[i], shares));
            lender[direct[i]].ops++;
        }
    }

    /// @dev Borrowers never repay. Each round liquidates, then lets every supplier exit as far as liquidity and the
    ///      queue allow, until no supplier holds shares or a round moves none. It terminates: no slot passes inside
    ///      the loop, so no interest or fee shares accrue and `_sharesLeft()` never grows.
    function _unwindByForcedExit() internal {
        _unwindPrelude();
        uint256 before = type(uint256).max;
        for (rounds = 1; rounds <= MAX_ROUNDS; ++rounds) {
            _forcedLiquidations();
            _forcedVaultExits();
            _forcedDirectExits();
            uint256 left = _sharesLeft();
            if (left == 0 || left == before) return;
            before = left;
        }
        assertTrue(false, "forced: rounds kept moving shares past the bug-detector cap");
    }

    /// @dev Keepers write off every underwater borrower and liquidate every unhealthy one as far as allowed, pass
    ///      after pass: a solvent liquidation of a borrower above LTV `1 / (2 - 1/LIF)` leaves it underwater.
    function _forcedLiquidations() internal {
        address k = keepers[0];
        bool acted = true;
        while (acted) {
            acted = false;
            for (uint256 i; i < borrowers.length; ++i) {
                address b = borrowers[i];
                if (_isUnderwater(b)) _writeOff(k, b);
                else if (_isUnhealthySolvent(b)) _liquidateSolvent(k, b, _maxSolventSeize(b), 0);
                else continue;
                acted = true;
            }
        }
    }

    /// @dev Every vault lender exits its whole balance: through the liquid leg when liquidity covers it, otherwise
    ///      by withdrawing the free liquidity and settling the rest. Shares whose budget buys no core supply share
    ///      cannot be settled and stay, asserted as that revert. No bad-debt root is left after the liquidations.
    function _forcedVaultExits() internal {
        Market storage m = _m();
        for (uint256 i; i < lenders.length; ++i) {
            address l = lenders[i];
            uint256 bal = m.vault.balanceOf(l);
            if (bal == 0) continue;
            uint256 liquid = _freeLiquidity();
            if (liquid > 0 && Erc4626Math.toAssets(m.vault, bal, Math.Rounding.Floor) <= liquid) {
                _bookOut(l, m.fallbackExitLiquid(l, bal, l));
                lender[l].ops++;
                continue;
            }
            if (liquid > 0) {
                m.vaultWithdraw(l, liquid);
                _bookOut(l, liquid);
                lender[l].ops++;
                bal = m.vault.balanceOf(l);
            }
            MorphoMarket memory mk = m.core.market(m.id);
            uint256 budget = Erc4626Math.toAssets(m.vault, bal, Math.Rounding.Floor)
                .toSharesDown(mk.totalSupplyAssets, mk.totalSupplyShares);
            if (budget == 0) {
                vm.prank(l);
                vm.expectRevert(ILidoLendERC4626.ZeroMorphoSupplyShares.selector);
                m.vault.fallbackExit(bal, l, l, 0);
                stalls++;
                continue;
            }
            assertFalse(m.controller.hasBadDebt(), "forced: bad debt left after liquidations");
            uint256 stallsBefore = predicted[Action.FallbackExit];
            _fallbackSettleLeg(ExitRequest(l, l, l, bal, 0), Action.FallbackExit);
            stalls += predicted[Action.FallbackExit] - stallsBefore;
        }
    }

    /// @dev Direct lenders and the fee recipient withdraw what liquidity allows, then settle the queue root cut after
    ///      cut while it quotes one, up to the same fifty cuts per round the vault allows a fallback exit.
    function _forcedDirectExits() internal {
        address[] memory xs = _directAndFee();
        for (uint256 i; i < xs.length; ++i) {
            _forcedDirectExit(xs[i]);
        }
    }

    /// @dev A position that fits the free liquidity is withdrawn by shares: an asset-anchored withdraw would strand
    ///      the sub-unit share remainder, which no settle can reach. A larger one withdraws exactly the free assets,
    ///      which strands nothing and, unlike a floored share count, leaves no free liquidity behind.
    function _forcedDirectExit(address x) internal {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 free = mk.totalSupplyAssets - mk.totalBorrowAssets;
        uint256 mine = _supplyAssetsDown(x);
        if (mine <= free) {
            uint256 shares = m.core.position(m.id, x).supplyShares;
            if (shares > 0) {
                _bookOut(x, m.coreWithdraw(x, shares));
                lender[x].ops++;
            }
        } else if (free > 0) {
            m.coreWithdrawAssets(x, free);
            _bookOut(x, free);
            lender[x].ops++;
        }
        for (uint256 k; k < 50; ++k) {
            uint256 shares = m.core.position(m.id, x).supplyShares;
            if (shares == 0) return;
            (address root, uint256 cut) = _rootCutFor(shares);
            if (cut == 0) return;
            assertFalse(_rateGate(cut), "forced: root cut crosses the share ceiling");
            assertFalse(m.controller.hasBadDebt(), "forced: bad debt left after liquidations");
            assertFalse(_tailGate(x, root, cut), "forced: root cut beyond the lender's tail");
            (uint256 seized, uint256 canceled) = m.coreSettle(x, root, cut, x);
            _bookCut(x, root, seized, canceled);
            lender[x].ops++;
        }
    }

    // ---
    // END STATE
    // ---

    /// @dev After a repayment unwind the market is empty but for gifted collateral and rounding dust: at most a unit
    ///      of debt per borrower, of idle loan per move and of vault value per lender operation.
    function _checkEndStateRepayment() internal view {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        assertEq(m.vault.totalSupply(), 0, "end: vault shares left");
        assertEq(mk.totalBorrowShares, 0, "end: debt shares left");
        assertLe(mk.totalBorrowAssets, borrowers.length, "end: debt dust above one unit per borrower");
        assertEq(m.collateralToken.balanceOf(address(m.core)), g.donatedCollateralToCore, "end: collateral left");
        _checkIdleDust();
        assertLe(m.vault.totalAssets(), _lenderOps(), "end: vault residue above one unit per lender op");
    }

    /// @dev After a forced-exit unwind, every share left must be one its holder could not have exited: a vault
    ///      lender's when `_exitBlocked` holds and no free liquidity is left, a direct lender's or the fee
    ///      recipient's only as a head-of-line stall. No direct dust remains, since it fits any free liquidity.
    function _checkEndStateForced() internal view {
        Market storage m = _m();
        _checkIdleDust();
        if (_sharesLeft() == 0) {
            assertLe(m.vault.totalAssets(), _lenderOps(), "forced: vault residue above one unit per lender op");
            return;
        }
        bool liquid = _freeLiquidity() > 0;
        for (uint256 i; i < lenders.length; ++i) {
            address l = lenders[i];
            uint256 bal = m.vault.balanceOf(l);
            if (bal == 0) continue;
            if (!liquid && _exitBlocked(bal)) continue;
            assertTrue(false, string.concat("forced: lender ", vm.toString(l), " could exit but did not"));
        }
        address[] memory xs = _directAndFee();
        for (uint256 i; i < xs.length; ++i) {
            address x = xs[i];
            uint256 shares = m.core.position(m.id, x).supplyShares;
            if (shares == 0) continue;
            (address root, uint256 cut) = _rootCutFor(shares);
            if (_isHeadOfLineStall(root, cut)) continue;
            if (root == address(0)) assertTrue(false, "forced: supplier holds shares with no debt left");
            else assertTrue(false, string.concat("forced: supplier ", vm.toString(x), " could exit but did not"));
        }
    }

    /// @dev A zero root cut against a root owing at most `100 * _priceUnits()`: the seizure floor (lender-settlement.md
    ///      "Seizure floor") stops every cut against it, so the residue is not one the unwind skipped.
    function _isHeadOfLineStall(address root, uint256 cut) internal view returns (bool) {
        return cut == 0 && root != address(0) && _debtUp(root) <= 100 * _priceUnits();
    }

    /// @dev The core holds every idle unit plus the gifts, with at most one unit of rounding dust per move on top.
    function _checkIdleDust() internal view {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 backed = mk.totalSupplyAssets - mk.totalBorrowAssets + g.donatedLoanToCore;
        uint256 coreLoan = m.loanToken.balanceOf(address(m.core));
        assertGe(coreLoan, backed, "end: idle not backed");
        assertLe(coreLoan - backed, g.moves, "end: idle dust above one unit per move");
    }

    /// @dev Each supplier holds, with what it took out, what its flows are worth at the supply index now, give or take
    ///      its own rounding: up to two units per operation or cut, and two for the final conversions. Other accounts'
    ///      rounding can only add to it, up to a unit per move.
    function _checkLenders() internal view {
        Market storage m = _m();
        for (uint256 i; i < lenders.length; ++i) {
            address l = lenders[i];
            // The vault's own quote on purpose: the position's worth is part of the value under assertion.
            _checkLender(l, m.vault.previewRedeem(m.vault.balanceOf(l)));
        }
        for (uint256 i; i < directLenders.length; ++i) {
            _checkLender(directLenders[i], _supplyAssetsDown(directLenders[i]));
        }
        _checkLender(feeRecipient, _supplyAssetsDown(feeRecipient));
    }

    function _checkLender(address l, uint256 positionValue) internal view {
        LenderLedger storage L = lender[l];
        uint256 dust = 2 * (1 + L.ops + L.cuts);
        uint256 owed = _scaledWorth(L.scaledIn);
        uint256 got = positionValue + _scaledWorth(L.scaledOut);
        assertGe(got + dust, owed, "lender: below its flows at the supply index");
        assertLe(got, owed + dust + g.moves, "lender: above its flows at the supply index");
        assertLe(L.collateralOutValue, L.debtCanceled, "lender: collateral worth more than the debt it settled");
    }

    /// @dev Per borrower: tokens are conserved, liquidations seized at most the repaid debt times the incentive and
    ///      settlements at most the canceled debt. Across borrowers, what was paid, written off or is still owed
    ///      beyond what was borrowed is the interest the model accrued, within rounding.
    function _checkBorrowers() internal view {
        Market storage m = _m();
        uint256 lif = _incentive();
        uint256 owedTotal;
        for (uint256 i; i < borrowers.length; ++i) {
            address b = borrowers[i];
            BorrowerLedger storage L = borrower[b];
            Position memory pos = m.core.position(m.id, b);
            assertEq(
                L.collateralFunded,
                m.collateralToken.balanceOf(b) + pos.collateral + L.collateralSeized,
                "borrower: collateral conservation"
            );
            assertEq(
                L.loanBorrowed + L.loanFunded + L.loanReceived,
                m.loanToken.balanceOf(b) + L.loanRepaid + L.loanRoutedAway,
                "borrower: loan conservation"
            );
            uint256 paid = L.loanRepaid + L.liqRepaid + L.settleCanceled + L.badDebt + _debtUp(b);
            assertGe(paid, L.loanBorrowed, "borrower: paid back less than borrowed");
            owedTotal += paid - L.loanBorrowed;
            assertLe(
                L.liqSeizedValue,
                L.liqRepaid.wMulDown(lif) + 2 * L.liquidations,
                "borrower: liquidation over the incentive"
            );
            assertGe(L.liqSeizedValue + 2 * L.liquidations, L.liqRepaid, "borrower: liquidation under the repaid debt");
            assertLe(L.settleSeizedValue, L.settleCanceled, "borrower: settlement over par");
        }
        assertApproxEqAbs(owedTotal, g.interest, g.moves + borrowers.length, "borrowers: interest paid != accrued");
    }

    // ---
    // TOTALS
    // ---

    function _supplierTotals() internal view returns (uint256 loanIn, uint256 loanOut, uint256 canceled) {
        for (uint256 i; i < lenders.length; ++i) {
            LenderLedger storage L = lender[lenders[i]];
            loanIn += L.loanIn;
            loanOut += L.loanOut;
            canceled += L.debtCanceled;
        }
        address[] memory direct = _directAndFee();
        for (uint256 i; i < direct.length; ++i) {
            LenderLedger storage L = lender[direct[i]];
            loanIn += L.loanIn;
            loanOut += L.loanOut;
            canceled += L.debtCanceled;
        }
    }

    function _walletTotals() internal view returns (uint256 loan, uint256 collateral, uint256 positions) {
        Market storage m = _m();
        address[] memory all = _everyone();
        for (uint256 i; i < all.length; ++i) {
            loan += m.loanToken.balanceOf(all[i]);
            collateral += m.collateralToken.balanceOf(all[i]);
        }
        for (uint256 i; i < borrowers.length; ++i) {
            positions += m.core.position(m.id, borrowers[i]).collateral;
        }
    }

    function _everyone() internal view returns (address[] memory all) {
        all = new address[](lenders.length + directLenders.length + borrowers.length + keepers.length + 2);
        uint256 n;
        for (uint256 i; i < lenders.length; ++i) {
            all[n++] = lenders[i];
        }
        for (uint256 i; i < directLenders.length; ++i) {
            all[n++] = directLenders[i];
        }
        for (uint256 i; i < borrowers.length; ++i) {
            all[n++] = borrowers[i];
        }
        for (uint256 i; i < keepers.length; ++i) {
            all[n++] = keepers[i];
        }
        all[n++] = feeRecipient;
        all[n] = bookService;
    }

    function _directAndFee() internal view returns (address[] memory xs) {
        xs = new address[](directLenders.length + 1);
        for (uint256 i; i < directLenders.length; ++i) {
            xs[i] = directLenders[i];
        }
        xs[directLenders.length] = feeRecipient;
    }

    function _sharesLeft() internal view returns (uint256 left) {
        Market storage m = _m();
        left = m.vault.totalSupply();
        address[] memory xs = _directAndFee();
        for (uint256 i; i < xs.length; ++i) {
            left += m.core.position(m.id, xs[i]).supplyShares;
        }
    }

    function _lenderOps() internal view returns (uint256 ops) {
        for (uint256 i; i < lenders.length; ++i) {
            ops += lender[lenders[i]].ops;
        }
    }

    /// @dev Loan units one collateral unit is worth at the highest price seen: the rounding a settlement can lose.
    function _priceUnits() internal view returns (uint256) {
        return Math.mulDiv(1, g.maxPrice, ORACLE_SCALE, Math.Rounding.Ceil);
    }

    /// @dev Liquidation incentive factor: `min(1.15, 1 / (1 - 0.3 * (1 - lltv)))`.
    function _incentive() internal view returns (uint256) {
        return Math.min(MAX_LIQUIDATION_INCENTIVE_FACTOR, WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - lltv)));
    }

    // ---
    // LOG
    // ---

    function _logHeader(uint256 duration, Unwind mode) internal view {
        console2.log("=== solvency simulation ===");
        console2.log("seed / price / loan decimals    ", seed, oraclePrice, _loanDecimals());
        console2.log("lenders / direct / borrowers    ", lenders.length, directLenders.length, borrowers.length);
        console2.log("keepers / days / unwind mode    ", keepers.length, duration / 1 days, uint256(mode));
    }

    function _logStats(uint256 iterations) internal view {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        console2.log("--- moves: count / amount, then nobody eligible / predicted reverts ---");
        for (uint256 a; a <= uint256(type(Action).max); ++a) {
            Action act = Action(a);
            if (count[act] + noEligible[act] + predicted[act] == 0) continue;
            console2.log(_name(act), count[act], amount[act]);
            if (noEligible[act] + predicted[act] != 0) {
                console2.log("        nobody / predicted", noEligible[act], predicted[act]);
            }
        }
        console2.log("iterations / moves / accruals   ", iterations, g.moves, g.accruals);
        console2.log("price min / max / crashes       ", g.minPrice, g.maxPrice, g.crashes);
        console2.log("interest / fee / bad debt       ", g.interest, g.feeAmount, g.badDebt);
        console2.log("supply index (1e36)             ", g.supplyIndex);
        console2.log("pauses / caps / bans            ", g.pauses, g.caps, g.bans);
        console2.log(
            "gifts: vault / core / collateral", g.donatedLoanToVault, g.donatedLoanToCore, g.donatedCollateralToCore
        );
        console2.log("third-party supply / shares     ", g.thirdPartyAssets, g.thirdPartyShares);
        console2.log("book filled / reward / service  ", g.bookFilled, g.bookReward, g.bookService);
        console2.log("forced rounds / stalls          ", rounds, stalls);
        console2.log(
            "end supply / borrow / vault left", mk.totalSupplyAssets, mk.totalBorrowAssets, m.vault.totalAssets()
        );
    }

    function _name(Action a) internal pure override returns (string memory) {
        string[42] memory names = [
            "Deposit",
            "Mint",
            "Withdraw",
            "Redeem",
            "SupplyCollateral",
            "Borrow",
            "RepayPartial",
            "RepayFull",
            "WithdrawCollateral",
            "SetSettlementLtv",
            "Settle",
            "FallbackExit",
            "Liquidate",
            "LiquidateBadDebt",
            "PriceStep",
            "Pause",
            "Resume",
            "Freeze",
            "Unfreeze",
            "SetSupplyCap",
            "CoreSupply",
            "CoreWithdraw",
            "CoreSettle",
            "DonateLoanToVault",
            "DonateLoanToCore",
            "DonateCollateralToCore",
            "ThirdPartySupply",
            "PlaceExitRequest",
            "FillExitRequest",
            "CancelExitRequest",
            "CoreSettleNonRoot",
            "TransferShares",
            "SetSettlementConfig",
            "SetActivationConfig",
            "PauseBook",
            "ResumeBook",
            "Crash",
            "FallbackExitScenario",
            "FillExitRequestScenario",
            "RemoveSupplyCap",
            "SettleScenario",
            "CoreSettleScenario"
        ];
        return names[uint256(a)];
    }
}
