// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {SettlementQueueLib} from "../../src/libs/SettlementQueueLib.sol";
import {MarketView, PositionView, SettlementConfig} from "../../src/types/SettlementTypes.sol";

uint256 constant WAD = 1e18;

/// @dev Harness exposing the internal settlement-queue library over a storage State (L0 via harness).
contract SQHarness {
    using SettlementQueueLib for SettlementQueueLib.State;

    SettlementQueueLib.State internal s;

    constructor() {
        s.init();
    }

    function sync(address b, PositionView memory p) external {
        s.sync(b, p);
    }

    function setSettlementConfig(SettlementConfig memory c) external {
        s.setSettlementConfig(c);
    }

    function setSettlementLtv(address b, uint256 ltv) external {
        s.setSettlementLtv(b, ltv);
    }

    function settlementLtvOf(address b) external view returns (uint256) {
        return s.settlementLtvOf(b);
    }

    function size() external view returns (uint256) {
        return s.size();
    }

    function peekRoot() external view returns (address) {
        return s.peekRoot();
    }

    function settlementBorrowers(uint256 o, uint256 m) external view returns (address[] memory, uint256[] memory) {
        return s.settlementBorrowers(o, m);
    }

    function allowedSlice(MarketView memory mv, address b, PositionView memory p) external view returns (uint256) {
        return s.allowedSlice(mv, b, p);
    }

    function sliceToLtv(uint256 d, uint256 c, uint256 t) external returns (uint256) {
        return SettlementQueueLib.sliceToLtv(d, c, t);
    }
}

/// @notice L0 unit/fuzz for `SettlementQueueLib`, modelled from REQUIREMENTS (the settlement
///         spec): settle cancels debt and seizes collateral of equal value at oracle price (no incentive),
///         so a cut that targets an LTV reduces both sides — `sliceToLtv` has the closed form
///         `Δ = (debt·WAD − ltv·collat) / (WAD − ltv)`, floored, clamped to 0 only (callers clamp to debt).
///         The queue keys borrowers by `borrowShares/collateral` (riskiest at the root) and enqueues every
///         live position. Formulas, rounding and revert ranges verified against the contract.
contract SettlementQueueLibTest is Test {
    SQHarness internal q;

    function setUp() public {
        q = new SQHarness();
    }

    function _b(uint256 i) internal pure returns (address) {
        return address(uint160(0x2000 + i));
    }

    /// @dev Independent recompute of `sliceToLtv` (floor division, clamp to 0 only — NOT to debt).
    function _expectedSlice(uint256 debt, uint256 collat, uint256 target) internal pure returns (uint256) {
        if (target >= WAD) return 0;
        if (debt * WAD <= target * collat) return 0;
        return (debt * WAD - target * collat) / (WAD - target);
    }

    function _pos(uint256 borrowShares, uint256 collateral) internal pure returns (PositionView memory) {
        return PositionView({borrowShares: borrowShares, collateral: collateral});
    }

    /// @dev Large 1:1 totals so `borrowShares.toAssetsUp` ~= borrowShares (the Morpho virtual-share offset
    ///      is negligible), keeping `debtAssets` predictable for the slice assertions.
    function _market(uint256 price) internal pure returns (MarketView memory) {
        return MarketView({
            totalSupplyAssets: 1e24,
            totalSupplyShares: 1e24,
            totalBorrowAssets: 1e24,
            totalBorrowShares: 1e24,
            price: price,
            lltv: 0.86e18
        });
    }

    function _setFloor(uint16 bps, uint96 fullCut) internal {
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: bps,
                sliceFloorAssets: 0,
                fullCutBelowCollateral: fullCut,
                ltvStepBps: 0,
                minBorrowCollateral: 0
            })
        );
    }

    // ── events ──

    event SettlementLtvSet(address indexed borrower, uint256 ltv);
    event SettlementConfigSet(SettlementConfig config);

    // ── mutations ──

    // ── config / borrower opt-in ──

    function test_setSettlementConfig_bpsBoundaryAllowed() public {
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 10_000,
                sliceFloorAssets: 1,
                fullCutBelowCollateral: 1,
                ltvStepBps: 10_000,
                minBorrowCollateral: 0
            })
        );
    }

    function testRevert_setSettlementConfig_sliceFloorBpsOver() public {
        vm.expectRevert(SettlementQueueLib.SettlementConfigOutOfRange.selector);
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 10_001,
                sliceFloorAssets: 0,
                fullCutBelowCollateral: 0,
                ltvStepBps: 0,
                minBorrowCollateral: 0
            })
        );
    }

    function testRevert_setSettlementConfig_ltvStepBpsOver() public {
        vm.expectRevert(SettlementQueueLib.SettlementConfigOutOfRange.selector);
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 0,
                sliceFloorAssets: 0,
                fullCutBelowCollateral: 0,
                ltvStepBps: 10_001,
                minBorrowCollateral: 0
            })
        );
    }

    function test_setSettlementLtv_storesAndClears() public {
        q.setSettlementLtv(_b(1), 0.7e18);
        assertEq(q.settlementLtvOf(_b(1)), 0.7e18, "stored");
        q.setSettlementLtv(_b(1), 0); // 0 clears the opt-in
        assertEq(q.settlementLtvOf(_b(1)), 0, "cleared");
    }

    function testRevert_setSettlementLtv_geWad() public {
        vm.expectRevert(SettlementQueueLib.SettlementLtvOutOfRange.selector);
        q.setSettlementLtv(_b(1), WAD);
    }

    function test_setSettlementLtv_justBelowWadAllowed() public {
        q.setSettlementLtv(_b(1), WAD - 1);
        assertEq(q.settlementLtvOf(_b(1)), WAD - 1, "WAD-1 allowed");
    }

    // ── queue: sync / peekRoot / settlementBorrowers ──

    function test_sync_enqueuesRemovesRekeys() public {
        // risk key = borrowShares/collateral; _b(1) riskier than _b(2)
        q.sync(_b(1), _pos(80, 100)); // ratio 0.8
        q.sync(_b(2), _pos(40, 100)); // ratio 0.4
        assertEq(q.size(), 2, "two enqueued");
        assertEq(q.peekRoot(), _b(1), "riskier is root");

        // zero collateral removes the position from the queue
        q.sync(_b(1), _pos(80, 0));
        assertEq(q.size(), 1, "removed on zero collateral");
        assertEq(q.peekRoot(), _b(2), "next is root");

        // re-key: make _b(2) less risky (still present, no duplicate)
        q.sync(_b(2), _pos(10, 100));
        assertEq(q.size(), 1, "still one (re-key, not insert)");
    }

    function test_sync_zeroBorrowShares_removes() public {
        q.sync(_b(1), _pos(50, 100));
        assertEq(q.size(), 1, "enqueued");
        q.sync(_b(1), _pos(0, 100)); // no debt -> removed
        assertEq(q.size(), 0, "removed on zero debt");
    }

    // ── events ──

    function test_setSettlementConfig_emitsEvent() public {
        SettlementConfig memory expected = SettlementConfig({
            sliceFloorBps: 2_000,
            sliceFloorAssets: 5,
            fullCutBelowCollateral: 7,
            ltvStepBps: 1_000,
            minBorrowCollateral: 0
        });
        vm.expectEmit(false, false, false, true, address(q));
        emit SettlementConfigSet(expected);
        q.setSettlementConfig(expected);
    }

    function test_setSettlementLtv_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(q));
        emit SettlementLtvSet(_b(1), 0.4e18);
        q.setSettlementLtv(_b(1), 0.4e18);
    }

    // ── queue: truncation & re-key ordering ──

    function test_sync_rekeyChangesRoot() public {
        q.sync(_b(1), _pos(50, 100)); // ratio 0.5
        q.sync(_b(2), _pos(40, 100)); // ratio 0.4 → b1 is root
        assertEq(q.peekRoot(), _b(1), "b1 root initially");
        q.sync(_b(1), _pos(10, 100)); // re-key b1 down to 0.1 → b2 becomes root
        assertEq(q.peekRoot(), _b(2), "re-key demoted b1; b2 is root");
        assertEq(q.size(), 2, "still two");
    }

    // ── views ──

    // ── sliceToLtv: closed form & boundaries ──

    function test_sliceToLtv_targetZero_isFullDebt() public {
        assertEq(q.sliceToLtv(80, 100, 0), 80, "target 0 cancels the full debt");
    }

    function test_sliceToLtv_targetAtOrAboveWad_isZero() public {
        assertEq(q.sliceToLtv(80, 100, WAD), 0, "target == WAD");
        assertEq(q.sliceToLtv(80, 100, WAD + 1), 0, "target > WAD");
    }

    function test_sliceToLtv_atOrBelowTarget_isZero() public {
        // debt·WAD (50e18) <= target·collat (0.6·100 = 60e18) -> already below target -> 0
        assertEq(q.sliceToLtv(50, 100, 0.6e18), 0, "already at/below target");
    }

    function test_sliceToLtv_closedForm() public {
        // debt 80, collat 100, target 0.5: Δ = (80 − 0.5·100)/(1−0.5) = 30/0.5 = 60
        uint256 got = q.sliceToLtv(80, 100, 0.5e18);
        assertEq(got, 60, "closed form");
        assertEq(got, _expectedSlice(80, 100, 0.5e18), "matches recompute");
        // post-cut LTV is exactly the target here: (80−60)/(100−60) = 20/40 = 0.5
        assertEq((80 - got) * WAD / (100 - got), 0.5e18, "post-cut LTV == target");
    }

    function test_sliceToLtv_collatBelowDebt_canExceedDebt_unclamped() public {
        // LTV > 1 (collat 50 < debt 100): Δ = (100 − 0.5·50)/0.5 = 75/0.5 = 150 > debt -> NOT clamped here
        uint256 got = q.sliceToLtv(100, 50, 0.5e18);
        assertEq(got, 150, "unclamped above debt (150 > debt 100; clamp lives in callers)");
    }

    function test_sliceToLtv_boundaryEquality() public {
        // debt·WAD (60e18) == target·collat (0.6·100=60e18) -> `<=` returns 0
        assertEq(q.sliceToLtv(60, 100, 0.6e18), 0, "equality -> 0");
        // a target meaningfully below the current LTV yields a >= 1 cut (a sub-unit cut would floor to 0)
        // (60*WAD - 0.5e18*100)/(WAD - 0.5e18) = 10e18/0.5e18 = 20
        assertEq(q.sliceToLtv(60, 100, 0.5e18), 20, "below target -> exact closed-form cut");
    }

    function testFuzz_sliceToLtv_matchesRecompute_andNoOvershoot(uint256 debt, uint256 collat, uint256 target) public {
        // Bound to avoid `debt*WAD` / `target*collat` overflow while keeping non-trivial magnitudes.
        debt = bound(debt, 0, 1e30);
        collat = bound(collat, 0, 1e30);
        target = bound(target, 0, WAD - 1);

        uint256 got = q.sliceToLtv(debt, collat, target);
        assertEq(got, _expectedSlice(debt, collat, target), "matches floor recompute");

        // Floor cuts no more than exact, so post-cut LTV never overshoots below the target.
        if (got > 0 && got < collat) {
            assertGe((debt - got) * WAD, target * (collat - got), "floor -> post-cut LTV >= target (no overshoot)");
        }
    }

    function testFuzz_sliceToLtv_monotonicInTarget(uint256 debt, uint256 collat, uint256 tLow, uint256 tHigh) public {
        debt = bound(debt, 1, 1e30);
        collat = bound(collat, debt, 1e30); // solvent domain (debt <= collat): settle targets solvent positions
        tLow = bound(tLow, 0, WAD - 2);
        tHigh = bound(tHigh, tLow + 1, WAD - 1);
        // Solvent: lower target cancels at least as much debt. dDelta/dt = WAD*(debt-collat)/(WAD-t)^2 >= 0
        // only when debt <= collat; the debt>collat case reverses and is outside the settle domain.
        assertGe(q.sliceToLtv(debt, collat, tLow), q.sliceToLtv(debt, collat, tHigh), "lower target -> >= cut");
    }

    // ── queue: sync / peekRoot / settlementBorrowers ──

    function test_peekRoot_empty_isZeroAddress() public {
        assertEq(q.peekRoot(), address(0), "empty queue peeks zero");
        assertEq(q.size(), 0, "empty");
    }

    function test_settlementBorrowers_pagination() public {
        q.sync(_b(1), _pos(90, 100)); // 0.9 riskiest
        q.sync(_b(2), _pos(60, 100)); // 0.6
        q.sync(_b(3), _pos(30, 100)); // 0.3

        (address[] memory all, uint256[] memory keys) = q.settlementBorrowers(0, 10);
        assertEq(all.length, 3, "all three");
        assertEq(all[0], _b(1), "riskiest first");
        assertGe(keys[0], keys[1], "keys descending");
        assertGe(keys[1], keys[2], "keys descending");

        (address[] memory page,) = q.settlementBorrowers(1, 1);
        assertEq(page.length, 1, "page size honoured");

        (address[] memory none,) = q.settlementBorrowers(5, 10);
        assertEq(none.length, 0, "offset past end -> empty");

        (address[] memory zero,) = q.settlementBorrowers(0, 0);
        assertEq(zero.length, 0, "maxCount 0 -> empty");
    }

    // ── allowedSlice: max-of-rules, floor only for the root, debt clamp, dust lift ──
    // Non-parity price (1.5e36) and non-1:1 shares isolate the slice logic while keeping values non-round.

    function test_allowedSlice_cappedAtDebt() public {
        // Root borrower, huge floor -> cut is clamped to the debt.
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 10_000, // 100% of debt
                sliceFloorAssets: 1e9, // absurd absolute floor
                fullCutBelowCollateral: 0,
                ltvStepBps: 0,
                minBorrowCollateral: 0
            })
        );
        q.sync(_b(1), _pos(100, 1_000)); // root
        // debtAssets == 100 (1:1 shares). collateralValue = 1000·1.5e36/1e36 = 1500.
        uint256 slice = q.allowedSlice(_market(1.5e36), _b(1), _pos(100, 1_000));
        assertEq(slice, 100, "clamped to debt");
    }

    function test_allowedSlice_nonRoot_getsNoFloor() public {
        // Two borrowers; _b(1) is riskier (root). A non-root borrower with NO settlement-LTV opt-in gets
        // neither the root cut nor a settlement cut -> allowedSlice is 0 (floor terms apply to root only).
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 5_000,
                sliceFloorAssets: 50,
                fullCutBelowCollateral: 0,
                ltvStepBps: 1_000,
                minBorrowCollateral: 0
            })
        );
        q.sync(_b(1), _pos(90, 100)); // root (riskier)
        q.sync(_b(2), _pos(40, 100)); // non-root
        uint256 slice = q.allowedSlice(_market(1.5e36), _b(2), _pos(40, 100));
        assertEq(slice, 0, "non-root without opt-in gets no floor and no cut");
    }

    function test_allowedSlice_root_getsFloor() public {
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 2_000, // 20% of debt = 20
                sliceFloorAssets: 0,
                fullCutBelowCollateral: 0,
                ltvStepBps: 0,
                minBorrowCollateral: 0
            })
        );
        q.sync(_b(1), _pos(100, 10_000)); // root, very low LTV so only the floor applies
        uint256 slice = q.allowedSlice(_market(1.5e36), _b(1), _pos(100, 10_000));
        assertEq(slice, 20, "root gets the 20% debt-fraction floor");
    }

    // ── allowedSlice: productive policy branches (settlement-LTV cut, LTV-step term, dust lift) ──

    function test_allowedSlice_settlementLtvCut_appliesToNonRoot() public {
        _setFloor(0, 0); // kill the root-cut floor terms so only the settlement-LTV cut can show
        q.sync(_b(1), _pos(90, 100)); // root (riskier)
        q.sync(_b(2), _pos(50, 100)); // non-root
        q.setSettlementLtv(_b(2), 0.3e18);
        // _b(2): debtAssets=50, collateralValue=150 (price 1.5e36). cut = sliceToLtv(50, 150, 0.3) = 7.
        uint256 slice = q.allowedSlice(_market(1.5e36), _b(2), _pos(50, 100));
        assertEq(slice, _expectedSlice(50, 150, 0.3e18), "settlement-LTV cut applied to a non-root borrower");
        assertEq(slice, 7, "exact");
    }

    function test_allowedSlice_ltvStepTerm_winsForRoot() public {
        // Root, 10% LTV step, negligible debt-fraction floor → the LTV-step term is the root cut.
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 1,
                sliceFloorAssets: 0,
                fullCutBelowCollateral: 0,
                ltvStepBps: 1_000,
                minBorrowCollateral: 0
            })
        );
        q.sync(_b(1), _pos(80, 100)); // root
        // debtAssets=80, collateralValue=150; target = currentLtv − ltvStepBps·WAD/BPS.
        uint256 currentLtv = 80 * WAD / 150;
        uint256 target = currentLtv - (1_000 * WAD / 10_000);
        uint256 slice = q.allowedSlice(_market(1.5e36), _b(1), _pos(80, 100));
        assertEq(slice, _expectedSlice(80, 150, target), "root cut is exactly the LTV-step term (beats the floor)");
    }

    function test_allowedSlice_dustLift_boundary() public {
        // partial slice = 20% of debt(100) = 20 loan; seized = 20·1e36/1.5e36 = 13 collateral; remaining = 87.
        // The lift uses a strict `<`, so remaining == threshold does NOT lift; threshold one higher does.
        q.sync(_b(1), _pos(100, 100));

        _setFloor(2_000, 87); // remaining == threshold → no lift
        assertEq(q.allowedSlice(_market(1.5e36), _b(1), _pos(100, 100)), 20, "remaining==threshold: no lift");

        _setFloor(2_000, 88); // remaining < threshold → lift to the full debt
        assertEq(q.allowedSlice(_market(1.5e36), _b(1), _pos(100, 100)), 100, "remaining<threshold: lift to debt");
    }

    function test_allowedSlice_fullCutZero_neverLifts() public {
        _setFloor(2_000, 0);
        q.sync(_b(1), _pos(100, 100));
        assertEq(q.allowedSlice(_market(1.5e36), _b(1), _pos(100, 100)), 20, "fullCutBelowCollateral==0 never lifts");
    }

    // ── queue: truncation & re-key ordering ──

    function test_settlementBorrowers_truncatesTail() public {
        q.sync(_b(1), _pos(90, 100));
        q.sync(_b(2), _pos(60, 100));
        q.sync(_b(3), _pos(30, 100));
        (address[] memory page,) = q.settlementBorrowers(1, 10); // offset 1, want 10, size 3 → 2
        assertEq(page.length, 2, "offset+maxCount > size truncates to size-offset");
    }
}
