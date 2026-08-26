// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SettlementQueueLib} from "../../src/libs/SettlementQueueLib.sol";
import {MarketView, PositionView, SettlementConfig, SettlementSlice} from "../../src/types/SettlementTypes.sol";

uint256 constant WAD = 1e18;

/// @dev Morpho's virtual amounts, restated here so the share recomputes stay independent of the library.
uint256 constant VIRTUAL_ASSETS = 1;
uint256 constant VIRTUAL_SHARES = 1e6;

/// @dev Share-rate ceiling a live market stays under: the controller caps the borrow-share rate at this, and
///      supply shares are minted at 1e6 per asset and only fall relative to assets as interest accrues.
uint256 constant MAX_SHARE_RATE = 1e7;

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

    function queueRootSlice(MarketView memory mv, address b, PositionView memory p)
        external
        view
        returns (uint256 sliceAssets)
    {
        (, sliceAssets) = s.allowedSliceAssets(mv, b, p);
    }

    function personalSlice(MarketView memory mv, address b, PositionView memory p)
        external
        view
        returns (uint256 sliceAssets)
    {
        (sliceAssets,) = s.allowedSliceAssets(mv, b, p);
    }

    function personalQuote(MarketView memory mv, address b, PositionView memory p)
        external
        view
        returns (SettlementSlice memory)
    {
        (uint256 sliceAssets,) = s.allowedSliceAssets(mv, b, p);
        return SettlementQueueLib.settlementSlice(mv, p, sliceAssets, 0);
    }

    function sliceToLtv(uint256 d, uint256 c, uint256 t) external returns (uint256) {
        return SettlementQueueLib.sliceToLtv(d, c, t);
    }

    function settlementSlice(MarketView memory mv, PositionView memory p, uint256 sliceAssets, uint256 budget)
        external
        pure
        returns (SettlementSlice memory)
    {
        return SettlementQueueLib.settlementSlice(mv, p, sliceAssets, budget);
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
            SettlementConfig({sliceFloorBps: bps, sliceFloorAssets: 0, fullCutBelowCollateral: fullCut, ltvStepBps: 0})
        );
    }

    // ── events ──

    event SettlementLtvSet(address indexed borrower, uint256 ltv);
    event SettlementConfigSet(SettlementConfig config);

    // ── mutations ──

    // ── config / borrower opt-in ──

    /// @dev sliceFloorBps and ltvStepBps at the 10_000 (100%) boundary are accepted (inclusive upper bound).
    function test_setSettlementConfig_bpsBoundaryAllowed() public {
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 10_000, sliceFloorAssets: 1, fullCutBelowCollateral: 1, ltvStepBps: 10_000
            })
        );
    }

    /// @dev A sliceFloorBps above 10_000 (100%) reverts SettlementConfigOutOfRange.
    function testRevert_setSettlementConfig_sliceFloorBpsOver() public {
        vm.expectRevert(SettlementQueueLib.SettlementConfigOutOfRange.selector);
        q.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 10_001, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 0})
        );
    }

    /// @dev An ltvStepBps above 10_000 (100%) reverts SettlementConfigOutOfRange.
    function testRevert_setSettlementConfig_ltvStepBpsOver() public {
        vm.expectRevert(SettlementQueueLib.SettlementConfigOutOfRange.selector);
        q.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 0, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 10_001})
        );
    }

    /// @dev A borrower's settlement-LTV opt-in is stored, and setting it to 0 clears the opt-in.
    function test_setSettlementLtv_storesAndClears() public {
        q.setSettlementLtv(_b(1), 0.7e18);
        assertEq(q.settlementLtvOf(_b(1)), 0.7e18, "stored");
        q.setSettlementLtv(_b(1), 0); // 0 clears the opt-in
        assertEq(q.settlementLtvOf(_b(1)), 0, "cleared");
    }

    /// @dev A settlement LTV at WAD (>= 100%) reverts SettlementLtvOutOfRange.
    function testRevert_setSettlementLtv_geWad() public {
        vm.expectRevert(SettlementQueueLib.SettlementLtvOutOfRange.selector);
        q.setSettlementLtv(_b(1), WAD);
    }

    /// @dev WAD-1 is the highest accepted settlement LTV (the WAD upper bound is exclusive).
    function test_setSettlementLtv_justBelowWadAllowed() public {
        q.setSettlementLtv(_b(1), WAD - 1);
        assertEq(q.settlementLtvOf(_b(1)), WAD - 1, "WAD-1 allowed");
    }

    // ── queue: sync / peekRoot / settlementBorrowers ──

    /// @dev sync enqueues live positions keyed by borrowShares/collateral (riskiest at root), removes on zero
    ///      collateral, and re-keys an existing borrower in place without inserting a duplicate.
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

    /// @dev The full risk key is `borrowShares * 1e18 / rawCollateral`; it must order positions above the former
    ///      uint96 saturation boundary by their real ratio, not insertion history.
    function test_sync_ordersKeysAboveUint96Boundary() public {
        uint256 lower = uint256(type(uint96).max) + 1;
        uint256 higher = lower + 1;
        q.sync(_b(1), _pos(lower, WAD));
        q.sync(_b(2), _pos(higher, WAD));

        assertEq(q.peekRoot(), _b(2), "higher full-precision key is root");
        (, uint256[] memory keys) = q.settlementBorrowers(0, 1);
        assertEq(keys[0], higher, "root exposes full key");
    }

    /// @dev An ordinary 80%-LTV position with an 18-decimal loan and 6-decimal collateral has a risk key far
    ///      above uint96, so its exact key must remain usable for ordering.
    function test_sync_sixDecimalCollateral_retainsOrdinaryLtvKey() public {
        uint256 rawCollateral = 1e6;
        uint256 borrowShares = 8e23;
        q.sync(_b(1), _pos(borrowShares, rawCollateral));

        (, uint256[] memory keys) = q.settlementBorrowers(0, 1);
        assertEq(keys[0], 8e35, "ordinary 6-decimal collateral key retained");
    }

    /// @dev A position synced with zero borrow shares (no debt) is removed from the queue.
    function test_sync_zeroBorrowShares_removes() public {
        q.sync(_b(1), _pos(50, 100));
        assertEq(q.size(), 1, "enqueued");
        q.sync(_b(1), _pos(0, 100)); // no debt -> removed
        assertEq(q.size(), 0, "removed on zero debt");
    }

    // ── events ──

    /// @dev setSettlementConfig emits SettlementConfigSet carrying the full config struct.
    function test_setSettlementConfig_emitsEvent() public {
        SettlementConfig memory expected =
            SettlementConfig({sliceFloorBps: 2_000, sliceFloorAssets: 5, fullCutBelowCollateral: 7, ltvStepBps: 1_000});
        vm.expectEmit(false, false, false, true, address(q));
        emit SettlementConfigSet(expected);
        q.setSettlementConfig(expected);
    }

    /// @dev setSettlementLtv emits SettlementLtvSet with the borrower and the new LTV.
    function test_setSettlementLtv_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(q));
        emit SettlementLtvSet(_b(1), 0.4e18);
        q.setSettlementLtv(_b(1), 0.4e18);
    }

    // ── queue: truncation & re-key ordering ──

    /// @dev Re-keying the root borrower to a lower risk ratio demotes it and promotes the next-riskiest to root.
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

    /// @dev A target LTV of 0 yields a slice equal to the full debt (cancel everything).
    function test_sliceToLtv_targetZero_isFullDebt() public {
        assertEq(q.sliceToLtv(80, 100, 0), 80, "target 0 cancels the full debt");
    }

    /// @dev A target at or above WAD yields a zero slice.
    function test_sliceToLtv_targetAtOrAboveWad_isZero() public {
        assertEq(q.sliceToLtv(80, 100, WAD), 0, "target == WAD");
        assertEq(q.sliceToLtv(80, 100, WAD + 1), 0, "target > WAD");
    }

    /// @dev A position already at or below the target LTV yields a zero slice.
    function test_sliceToLtv_atOrBelowTarget_isZero() public {
        // debt·WAD (50e18) <= target·collat (0.6·100 = 60e18) -> already below target -> 0
        assertEq(q.sliceToLtv(50, 100, 0.6e18), 0, "already at/below target");
    }

    /// @dev The slice matches the closed form Δ=(debt·WAD−ltv·collat)/(WAD−ltv) and drives post-cut LTV to
    /// target.
    function test_sliceToLtv_closedForm() public {
        // debt 80, collat 100, target 0.5: Δ = (80 − 0.5·100)/(1−0.5) = 30/0.5 = 60
        uint256 got = q.sliceToLtv(80, 100, 0.5e18);
        assertEq(got, 60, "closed form");
        assertEq(got, _expectedSlice(80, 100, 0.5e18), "matches recompute");
        // post-cut LTV is exactly the target here: (80−60)/(100−60) = 20/40 = 0.5
        assertEq((80 - got) * WAD / (100 - got), 0.5e18, "post-cut LTV == target");
    }

    /// @dev When collateral < debt (LTV>1) the closed-form slice can exceed debt and is returned unclamped.
    function test_sliceToLtv_collatBelowDebt_canExceedDebt_unclamped() public {
        // LTV > 1 (collat 50 < debt 100): Δ = (100 − 0.5·50)/0.5 = 75/0.5 = 150 > debt -> NOT clamped here
        uint256 got = q.sliceToLtv(100, 50, 0.5e18);
        assertEq(got, 150, "unclamped above debt (150 > debt 100; clamp lives in callers)");
    }

    /// @dev At the equality debt·WAD == target·collat the slice is 0; just below target it is the exact floored cut.
    function test_sliceToLtv_boundaryEquality() public {
        // debt·WAD (60e18) == target·collat (0.6·100=60e18) -> `<=` returns 0
        assertEq(q.sliceToLtv(60, 100, 0.6e18), 0, "equality -> 0");
        // a target meaningfully below the current LTV yields a >= 1 cut (a sub-unit cut would floor to 0)
        // (60*WAD - 0.5e18*100)/(WAD - 0.5e18) = 10e18/0.5e18 = 20
        assertEq(q.sliceToLtv(60, 100, 0.5e18), 20, "below target -> exact closed-form cut");
    }

    /// @dev Across fuzzed inputs the slice equals the floored recompute and post-cut LTV never overshoots the target.
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

    /// @dev In the solvent domain, a lower target LTV yields a slice at least as large as a higher target.
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

    /// @dev An empty queue peeks the zero address and reports size 0.
    function test_peekRoot_empty_isZeroAddress() public {
        assertEq(q.peekRoot(), address(0), "empty queue peeks zero");
        assertEq(q.size(), 0, "empty");
    }

    /// @dev settlementBorrowers lists borrowers in descending risk order and honours offset/maxCount pagination
    ///      (offset past the end or a zero maxCount returns an empty page).
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

    /// @dev Targeted settlement excludes the queue-root policy. With a 30-asset root floor and a 20-asset personal
    ///      slice, the automatic path gets 30 while the targeted path gets 20.
    function test_allowedSlice_canExcludeRootPolicy() public {
        PositionView memory root = _pos(75, 100);
        q.sync(_b(1), root);
        q.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 0, sliceFloorAssets: 30, fullCutBelowCollateral: 0, ltvStepBps: 0})
        );
        q.setSettlementLtv(_b(1), 0.6875e18);

        assertEq(q.queueRootSlice(_market(1e36), _b(1), root), 30, "queue-root policy slice");
        assertEq(q.personalSlice(_market(1e36), _b(1), root), 20, "targeted path uses personal policy only");
    }

    // ── allowedSlice: independent personal and prospective queue-root quotes ──
    // Non-parity price (1.5e36) and non-1:1 shares isolate the slice logic while keeping values non-round.

    /// @dev An oversized floor for the root borrower is clamped down to the borrower's debt.
    function test_allowedSlice_cappedAtDebt() public {
        // Root borrower, huge floor -> cut is clamped to the debt.
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 10_000, // 100% of debt
                sliceFloorAssets: 1e9, // absurd absolute floor
                fullCutBelowCollateral: 0,
                ltvStepBps: 0
            })
        );
        q.sync(_b(1), _pos(100, 1_000)); // root
        // debtAssets == 100 (1:1 shares). collateralValue = 1000·1.5e36/1e36 = 1500.
        uint256 slice = q.queueRootSlice(_market(1.5e36), _b(1), _pos(100, 1_000));
        assertEq(slice, 100, "clamped to debt");
    }

    /// @dev The absolute floor (`sliceFloorAssets`) can win the slice max and is returned UNCLAMPED when it is
    ///      the largest term yet still below the borrower's debt — a floor branch the other tests miss (they only
    ///      set `sliceFloorAssets` large enough to clamp to debt). ltvStep is disabled to isolate the abs term.
    function test_allowedSlice_absoluteFloorWins_belowDebt() public {
        q.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 100, sliceFloorAssets: 900, fullCutBelowCollateral: 0, ltvStepBps: 0})
        );
        q.sync(_b(1), _pos(1_000, 1_000)); // root; debtAssets == 1000, collateralValue = 1500 at price 1.5e36
        // bps term = 1% of debt = 10; abs floor 900 is the largest term and < debt (1000) -> returned as-is.
        uint256 slice = q.queueRootSlice(_market(1.5e36), _b(1), _pos(1_000, 1_000));
        assertEq(slice, 900, "absolute floor wins, returned unclamped (below debt)");
    }

    /// @dev The queue-root quote is prospective: a non-root exposes the cut it would receive if it became root,
    ///      while its personal quote remains zero without an opt-in.
    function test_allowedSlices_nonRoot_exposesProspectiveQueueRootCut() public {
        q.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 5_000, sliceFloorAssets: 50, fullCutBelowCollateral: 0, ltvStepBps: 1_000})
        );
        q.sync(_b(1), _pos(90, 100)); // root (riskier)
        q.sync(_b(2), _pos(40, 100)); // non-root
        assertEq(q.personalSlice(_market(1.5e36), _b(2), _pos(40, 100)), 0, "no personal opt-in");
        assertEq(q.queueRootSlice(_market(1.5e36), _b(2), _pos(40, 100)), 40, "prospective cut capped at debt");
    }

    /// @dev The root borrower receives the bps debt-fraction floor when no larger term applies.
    function test_allowedSlice_root_getsFloor() public {
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 2_000, // 20% of debt = 20
                sliceFloorAssets: 0,
                fullCutBelowCollateral: 0,
                ltvStepBps: 0
            })
        );
        q.sync(_b(1), _pos(100, 10_000)); // root, very low LTV so only the floor applies
        uint256 slice = q.queueRootSlice(_market(1.5e36), _b(1), _pos(100, 10_000));
        assertEq(slice, 20, "root gets the 20% debt-fraction floor");
    }

    // ── allowedSlice: productive policy branches (settlement-LTV cut, LTV-step term, dust lift) ──

    /// @dev A non-root borrower's settlement-LTV opt-in produces the sliceToLtv cut against its collateral value.
    function test_allowedSlice_settlementLtvCut_appliesToNonRoot() public {
        _setFloor(0, 0); // kill the root-cut floor terms so only the settlement-LTV cut can show
        q.sync(_b(1), _pos(90, 100)); // root (riskier)
        q.sync(_b(2), _pos(50, 100)); // non-root
        q.setSettlementLtv(_b(2), 0.3e18);
        // _b(2): debtAssets=50, collateralValue=150 (price 1.5e36). cut = sliceToLtv(50, 150, 0.3) = 7.
        uint256 slice = q.personalSlice(_market(1.5e36), _b(2), _pos(50, 100));
        assertEq(slice, _expectedSlice(50, 150, 0.3e18), "settlement-LTV cut applied to a non-root borrower");
        assertEq(slice, 7, "exact");
    }

    /// @dev For the root borrower the LTV-step term (current LTV minus the step) beats the debt-fraction floor.
    function test_allowedSlice_ltvStepTerm_winsForRoot() public {
        // Root, 10% LTV step, negligible debt-fraction floor → the LTV-step term is the root cut.
        q.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 1, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 1_000})
        );
        q.sync(_b(1), _pos(80, 100)); // root
        // debtAssets=80, collateralValue=150; target = currentLtv − ltvStepBps·WAD/BPS.
        uint256 currentLtv = 80 * WAD / 150;
        uint256 target = currentLtv - (1_000 * WAD / 10_000);
        uint256 slice = q.queueRootSlice(_market(1.5e36), _b(1), _pos(80, 100));
        assertEq(slice, _expectedSlice(80, 150, target), "root cut is exactly the LTV-step term (beats the floor)");
    }

    /// @dev The dust lift uses a strict `<`: remaining == threshold does not lift, remaining < threshold lifts to
    ///      the full debt.
    function test_allowedSlice_dustLift_boundary() public {
        // partial slice = 20% of debt(100) = 20 loan; seized = 20·1e36/1.5e36 = 13 collateral; remaining = 87.
        // The lift uses a strict `<`, so remaining == threshold does NOT lift; threshold one higher does.
        q.sync(_b(1), _pos(100, 100));

        _setFloor(2_000, 87); // remaining == threshold → no lift
        assertEq(q.queueRootSlice(_market(1.5e36), _b(1), _pos(100, 100)), 20, "remaining==threshold: no lift");

        _setFloor(2_000, 88); // remaining < threshold → lift to the full debt
        assertEq(q.queueRootSlice(_market(1.5e36), _b(1), _pos(100, 100)), 100, "remaining<threshold: lift to debt");
    }

    /// @dev The collateral dust sweep applies only to queue-root policy. Both nominal cuts would leave collateral
    ///      below the floor, but the personal target remains partial while the queue-root quote becomes a full close.
    function test_allowedSlices_dustLift_appliesOnlyToQueueRoot() public {
        PositionView memory position = _pos(100, 100);
        q.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 2_000, sliceFloorAssets: 0, fullCutBelowCollateral: 98, ltvStepBps: 0})
        );
        q.setSettlementLtv(_b(1), 0.65e18);

        assertEq(q.personalSlice(_market(1.5e36), _b(1), position), 7, "personal cut ignores dust sweep");
        assertEq(q.queueRootSlice(_market(1.5e36), _b(1), position), 100, "queue-root cut is promoted");
    }

    /// @dev Removing personal dust promotion does not change share conversion: a target-LTV asset cut one unit below
    ///      the debt may still round up to every borrow share. This is a rounding full close, not a dust-policy lift.
    function test_personalQuote_nearFullAssetCutMayRoundToFullBorrowShares() public {
        MarketView memory marketView = MarketView({
            totalSupplyAssets: 1e18,
            totalSupplyShares: 1e6,
            totalBorrowAssets: 1e18,
            totalBorrowShares: 1e6,
            price: 1e36,
            lltv: 0.86e18
        });
        PositionView memory position = _pos(2, 1_000_000_000_002);
        q.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 0, sliceFloorAssets: 0, fullCutBelowCollateral: type(uint96).max, ltvStepBps: 0
            })
        );
        q.setSettlementLtv(_b(1), 0.5e18);

        uint256 personalSliceAssets = q.personalSlice(marketView, _b(1), position);
        SettlementSlice memory quote = q.personalQuote(marketView, _b(1), position);

        assertEq(personalSliceAssets, 1_000_000_000_000, "target cut stays one asset below the debt");
        assertEq(quote.borrowShares, position.borrowShares, "up-rounding reaches every borrow share");
        assertEq(quote.remainingBorrowShares, 0, "share rounding identifies a full close");
    }

    /// @dev A zero fullCutBelowCollateral disables the dust lift entirely.
    function test_allowedSlice_fullCutZero_neverLifts() public {
        _setFloor(2_000, 0);
        q.sync(_b(1), _pos(100, 100));
        assertEq(q.queueRootSlice(_market(1.5e36), _b(1), _pos(100, 100)), 20, "fullCutBelowCollateral==0 never lifts");
    }

    // ── queue: truncation & re-key ordering ──

    /// @dev When offset+maxCount exceeds size the page truncates to the remaining (size-offset) entries.
    function test_settlementBorrowers_truncatesTail() public {
        q.sync(_b(1), _pos(90, 100));
        q.sync(_b(2), _pos(60, 100));
        q.sync(_b(3), _pos(30, 100));
        (address[] memory page,) = q.settlementBorrowers(1, 10); // offset 1, want 10, size 3 → 2
        assertEq(page.length, 2, "offset+maxCount > size truncates to size-offset");
    }

    // ── budget capping ──

    /// @dev Independent recompute of the supply a borrow-share cut burns, from the Morpho share formulas:
    ///      debt is `toAssetsUp` of the cut, then the burn is `toSharesUp` of that debt.
    function _coreBurn(MarketView memory mv, uint256 borrowShares) internal pure returns (uint256) {
        uint256 debtAssets = Math.mulDiv(
            borrowShares,
            mv.totalBorrowAssets + VIRTUAL_ASSETS,
            mv.totalBorrowShares + VIRTUAL_SHARES,
            Math.Rounding.Ceil
        );
        return Math.mulDiv(
            debtAssets, mv.totalSupplyShares + VIRTUAL_SHARES, mv.totalSupplyAssets + VIRTUAL_ASSETS, Math.Rounding.Ceil
        );
    }

    /// @dev A budget beyond the cut's cost leaves every field alone, matching the unshrunk policy quote.
    function test_settlementSlice_ampleBudget_matchesTheUnshrunkQuote() public view {
        MarketView memory mv = _market(1.5e36);
        PositionView memory p = _pos(100e18, 500e18);
        SettlementSlice memory policy = q.settlementSlice(mv, p, 40e18, 0);
        SettlementSlice memory funded = q.settlementSlice(mv, p, 40e18, type(uint128).max);

        assertEq(funded.borrowShares, policy.borrowShares, "borrowShares untouched");
        assertEq(funded.supplyShares, policy.supplyShares, "supplyShares untouched");
        assertEq(funded.remainingBorrowShares, policy.remainingBorrowShares, "remaining untouched");
    }

    /// @dev A short budget shrinks the cut and the shaved shares land in the remainder, so the three fields keep
    ///      describing one and the same position.
    function test_settlementSlice_shortBudget_keepsFieldsConsistent() public view {
        MarketView memory mv = _market(1.5e36);
        PositionView memory p = _pos(100e18, 500e18);
        SettlementSlice memory policy = q.settlementSlice(mv, p, 40e18, 0);
        SettlementSlice memory funded = q.settlementSlice(mv, p, 40e18, policy.supplyShares / 4);

        assertLt(funded.borrowShares, policy.borrowShares, "cut shrank");
        assertEq(
            funded.borrowShares + funded.remainingBorrowShares, p.borrowShares, "fields still span the whole position"
        );
        assertEq(funded.supplyShares, _coreBurn(mv, funded.borrowShares), "supply cost recomputed for the shrunk cut");
    }

    /// @dev A positive budget that funds no borrow share at all is reported as an unavailable cut, not a
    ///      partial one. (0 is the sentinel for "no budget cap" and is covered above.)
    function test_settlementSlice_unaffordable_isUnavailable() public view {
        MarketView memory mv = _market(1.5e36);
        SettlementSlice memory funded = q.settlementSlice(mv, _pos(100e18, 500e18), 40e18, 1);

        assertEq(funded.borrowShares, 0, "no cut");
        assertEq(funded.supplyShares, 0, "no cost");
        assertEq(funded.remainingBorrowShares, 100e18, "an unavailable cut reports the untouched debt");
    }

    // ── seizure floor ──

    /// @dev A market where one borrow/supply share is worth exactly one loan asset in both directions, so a slice
    ///      of `n` loan assets is a cut of `n` borrow shares and the seizure floor is the only rounding left.
    function _unitShareMarket(uint256 price) internal pure returns (MarketView memory) {
        return MarketView({
            totalSupplyAssets: 1e24,
            totalSupplyShares: 1e24 + 1 - VIRTUAL_SHARES,
            totalBorrowAssets: 1e24,
            totalBorrowShares: 1e24 + 1 - VIRTUAL_SHARES,
            price: price,
            lltv: 0.86e18
        });
    }

    /// @dev The core prices the seizure off the cut's debt rounded down, so above `ORACLE_PRICE_SCALE` a
    ///      one-loan-asset cut buys no whole collateral unit. That cut is unavailable, not a partial.
    function test_settlementSlice_cutBelowSeizureFloor_isUnavailable() public view {
        MarketView memory mv = _unitShareMarket(1.5e36);
        PositionView memory p = _pos(100e18, 500e18);

        SettlementSlice memory funded = q.settlementSlice(mv, p, 1, 0);
        assertEq(funded.borrowShares, 0, "no cut");
        assertEq(funded.supplyShares, 0, "no cost");
        assertEq(funded.remainingBorrowShares, p.borrowShares, "an unavailable cut reports the untouched debt");

        // ceil(1.5e36 / 1e36) == 2 loan assets is the smallest cut that seizes a whole unit.
        SettlementSlice memory ok = q.settlementSlice(mv, p, 2, 0);
        assertEq(ok.borrowShares, 2, "two loan assets clears the floor");
        assertEq(ok.remainingBorrowShares, p.borrowShares - 2, "and is a partial cut");
    }

    /// @dev The floor is `ceil(price / ORACLE_PRICE_SCALE)` loan assets: the same one-asset cut is available at or
    ///      below parity and unavailable above it.
    function test_settlementSlice_seizureFloorTracksPrice() public view {
        PositionView memory p = _pos(100e18, 500e18);

        assertEq(q.settlementSlice(_unitShareMarket(0.5e36), p, 1, 0).borrowShares, 1, "below parity: available");
        assertEq(q.settlementSlice(_unitShareMarket(1e36), p, 1, 0).borrowShares, 1, "at parity: available");
        assertEq(q.settlementSlice(_unitShareMarket(1e36 + 1), p, 1, 0).borrowShares, 0, "one wei above: unavailable");
    }

    /// @dev A budget shrink lands on the floor just as a policy amount can. `1` is the sentinel for the unshrunk
    ///      quote, so budget the exact cost of the sub-floor cut instead.
    function test_settlementSlice_budgetShrunkOntoFloor_isUnavailable() public view {
        MarketView memory mv = _unitShareMarket(1.5e36);
        PositionView memory p = _pos(100e18, 500e18);

        SettlementSlice memory oneAssetCut = q.settlementSlice(_unitShareMarket(1e36), p, 1, 0);
        assertEq(oneAssetCut.borrowShares, 1, "the one-asset cut exists at parity");

        SettlementSlice memory funded = q.settlementSlice(mv, p, 40e18, oneAssetCut.supplyShares);
        assertEq(funded.borrowShares, 0, "a budget that only funds a sub-floor cut reports no cut");
        assertEq(funded.supplyShares, 0, "no cost");
        assertEq(funded.remainingBorrowShares, p.borrowShares, "an unavailable cut reports the untouched debt");
    }

    /// @dev A market with no price seizes nothing (and would divide by zero in the core), so no cut is quoted.
    function test_settlementSlice_zeroPrice_isUnavailable() public view {
        SettlementSlice memory funded = q.settlementSlice(_unitShareMarket(0), _pos(100e18, 500e18), 40e18, 0);
        assertEq(funded.borrowShares, 0, "no cut without a price");
        assertEq(funded.supplyShares, 0, "no cost");
        assertEq(funded.remainingBorrowShares, 100e18, "an unavailable cut reports the untouched debt");
    }

    /// @dev The property the core's `settle` requires: every cut the library quotes seizes at least one whole
    ///      collateral unit, so a quoted handle is never rejected for seizing nothing.
    /// forge-config: default.fuzz.runs = 20000
    function testFuzz_settlementSlice_quotedCutSeizesCollateral(
        uint256 borrowShares,
        uint256 collateral,
        uint256 sliceAssets,
        uint256 budgetSupplyShares,
        uint256 price,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares
    ) public view {
        MarketView memory mv = _fuzzMarket(totalBorrowAssets, totalBorrowShares, totalSupplyAssets, totalSupplyShares);
        mv.price = bound(price, 0, 1e40);
        PositionView memory p = _fuzzPosition(mv, borrowShares, collateral);
        sliceAssets = bound(sliceAssets, 1, 1e30);
        budgetSupplyShares = bound(budgetSupplyShares, 0, mv.totalSupplyShares + VIRTUAL_SHARES);

        SettlementSlice memory funded = q.settlementSlice(mv, p, sliceAssets, budgetSupplyShares);
        if (funded.borrowShares == 0) return;

        assertGt(mv.price, 0, "a quoted cut implies a priced market");
        uint256 cutAssets = Math.mulDiv(
            funded.borrowShares,
            mv.totalBorrowAssets + VIRTUAL_ASSETS,
            mv.totalBorrowShares + VIRTUAL_SHARES,
            Math.Rounding.Floor
        );
        assertGt(Math.mulDiv(cutAssets, ORACLE_PRICE_SCALE, mv.price), 0, "the quoted cut seizes a collateral unit");
    }

    /// @dev The contract the vault relies on: whatever budget a caller brings, the supply the core burns for the
    ///      returned handle fits inside it, so the caller's budget accounting can never underflow.
    /// forge-config: default.fuzz.runs = 20000
    function testFuzz_settlementSlice_burnFitsInBudget(
        uint256 borrowShares,
        uint256 collateral,
        uint256 sliceAssets,
        uint256 budgetSupplyShares,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares
    ) public view {
        MarketView memory mv = _fuzzMarket(totalBorrowAssets, totalBorrowShares, totalSupplyAssets, totalSupplyShares);
        PositionView memory p = _fuzzPosition(mv, borrowShares, collateral);
        sliceAssets = bound(sliceAssets, 1, 1e30);
        budgetSupplyShares = bound(budgetSupplyShares, 1, mv.totalSupplyShares + VIRTUAL_SHARES);

        SettlementSlice memory funded = q.settlementSlice(mv, p, sliceAssets, budgetSupplyShares);
        if (funded.borrowShares == 0) return;

        assertLe(_coreBurn(mv, funded.borrowShares), budgetSupplyShares, "burn fits the budget");
    }

    /// @dev `supplyShares` is the cut's cost, not a low estimate: budgeting exactly it funds the whole policy cut.
    /// forge-config: default.fuzz.runs = 20000
    function testFuzz_quotedSupplyCost_fundsTheQuotedCut(
        uint256 borrowShares,
        uint256 collateral,
        uint256 sliceAssets,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 totalSupplyAssets,
        uint256 totalSupplyShares
    ) public view {
        MarketView memory mv = _fuzzMarket(totalBorrowAssets, totalBorrowShares, totalSupplyAssets, totalSupplyShares);
        PositionView memory p = _fuzzPosition(mv, borrowShares, collateral);
        sliceAssets = bound(sliceAssets, 1, 1e30);

        SettlementSlice memory policy = q.settlementSlice(mv, p, sliceAssets, 0);
        if (policy.borrowShares == 0) return;

        SettlementSlice memory funded = q.settlementSlice(mv, p, sliceAssets, policy.supplyShares);
        assertEq(funded.borrowShares, policy.borrowShares, "the quoted cost funds the quoted cut");
    }

    /// @dev A market snapshot with share rates a live market can actually hold. Leaving assets and shares
    ///      independent lets the fuzzer build books that no market reaches (all debt, no debt shares), where the
    ///      core's own share math overflows long before any settlement policy runs.
    function _fuzzMarket(uint256 tba, uint256 tbs, uint256 tsa, uint256 tss) internal pure returns (MarketView memory) {
        uint256 borrowAssets = bound(tba, 0, 1e30);
        uint256 supplyAssets = bound(tsa, 0, 1e30);
        return MarketView({
            totalSupplyAssets: supplyAssets,
            totalSupplyShares: bound(tss, 0, MAX_SHARE_RATE * (supplyAssets + VIRTUAL_ASSETS)),
            totalBorrowAssets: borrowAssets,
            totalBorrowShares: bound(tbs, 0, MAX_SHARE_RATE * (borrowAssets + VIRTUAL_ASSETS)),
            price: 1.5e36,
            lltv: 0.86e18
        });
    }

    /// @dev A position never holds more borrow shares than the book, and a lender never more supply shares.
    function _fuzzPosition(MarketView memory mv, uint256 borrowShares, uint256 collateral)
        internal
        pure
        returns (PositionView memory)
    {
        uint256 shares = mv.totalBorrowShares == 0 ? 0 : bound(borrowShares, 1, mv.totalBorrowShares);
        return _pos(shares, bound(collateral, 1, 1e30));
    }
}
