// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TrailingAnchorOracleBase} from "../../../src/oracle/TrailingAnchorOracleBase.sol";

import {
    TrailingAnchorOracleModel,
    TrailingAnchorOracleState,
    TrailingAnchorOracleUpdate
} from "../../setup/TrailingAnchorOracleModel.sol";
import {INavSourceMock} from "../../setup/NavSourceMocks.sol";

/// @notice Drives one anchor oracle through every state-changing entry point: the source and time move, anyone calls
///         `updateAnchor()`, the price acceptor accepts prices in a range, and the manager changes the parameters and
///         suspends pricing.
/// @dev The handler keeps a shadow of the stored state and updates it by the model only. Before each call it predicts,
///      from the shadow, whether the call succeeds and otherwise the exact revert data, so a call the rules allow
///      reverts the run and a call they refuse must revert with the predicted error. Ghost counters record what the
///      suite's invariants read, each checked against the bounds, speed, step, floor and ceiling formulas rather than
///      the model.
contract TrailingAnchorOracleHandler is Test {
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant WAD = 1e18;

    TrailingAnchorOracleBase public immutable ORACLE;
    INavSourceMock internal immutable SOURCE;
    address internal immutable MANAGER;
    address internal immutable PRICE_ACCEPTOR;

    TrailingAnchorOracleState internal shadow;

    /// @dev Ghost violations: an update that stopped or changed a price returned just before it, a parameter change
    ///      that changed a returned price, and an anchor move that is neither a drift toward a price within the bounds
    ///      inside the speeds' reach nor a move onto a pending anchor recorded at least the delay before.
    uint256 public stoppedPrices;
    uint256 public parameterPriceChanges;
    uint256 public strayAnchorMoves;
    /// @dev Ghost violations: an update that set the anchor under the floor below `expectedHighWaterMark`, when the
    ///      anchor sat above it, and one that left the anchor further over `expectedHighWaterMark` than both
    ///      `maxAnchorAboveMark` of it and its distance before the update.
    uint256 public floorBreaches;
    uint256 public ceilingBreaches;

    /// @dev The high-water mark by its rule, from the oracle's anchor after each call: the seed or the last acceptance,
    ///      raised by a drift up to max(H, A' − max(A − H, 0)) and left by a re-anchor.
    uint256 public expectedHighWaterMark;
    /// @dev How far the anchor sat over `expectedHighWaterMark` at the last parameter change, zero after an acceptance:
    ///      a narrower `maxAnchorAboveMark` may leave the anchor that high.
    uint256 public gapAtParameterChange;

    /// @dev When `setPricingResumesAt` last succeeded.
    uint256 public suspensionSetAt;

    /// @dev Coverage counters, logged after the campaign.
    mapping(bytes32 action => uint256) public succeeded;
    mapping(bytes32 action => uint256) public refused;

    constructor(TrailingAnchorOracleBase oracle, INavSourceMock source, address manager, address priceAcceptor) {
        ORACLE = oracle;
        SOURCE = source;
        MANAGER = manager;
        PRICE_ACCEPTOR = priceAcceptor;
        shadow = TrailingAnchorOracleModel.read(oracle);
        expectedHighWaterMark = oracle.anchorPrice();
    }

    function shadowState() external view returns (TrailingAnchorOracleState memory) {
        return shadow;
    }

    /// @dev The revert `price()` must give now, or nothing.
    function predictPriceRevert() external view returns (bytes memory) {
        return shadow.priceRevert(SOURCE.currentPrice(), SOURCE.isDown(), block.timestamp);
    }

    // ---
    // THE WORLD
    // ---

    /// @dev Keeps the source within 0.04% of the anchor, inside the default bounds.
    function stepSource(uint256 seed) external {
        _setSourceAround(seed, 0.9996e18, 1.0004e18);
    }

    /// @dev Moves the source within 2% of the anchor, past the bounds.
    function moveSource(uint256 seed) external {
        _setSourceAround(seed, 0.98e18, 1.02e18);
    }

    /// @dev Jumps the source within 15% of the anchor.
    function jumpSource(uint256 seed) external {
        _setSourceAround(seed, 0.85e18, 1.15e18);
    }

    /// @dev Takes the source down on one pick in eight and brings it back otherwise, so outages stay short. The pick is
    ///      a hash of the seed, since the fuzzer favours small seeds and zero would keep the source down.
    function setSourceDown(uint256 seed) external {
        SOURCE.setDown(_pick(seed, "down") % 8 == 0);
    }

    /// @dev Up to three days at once.
    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 3 days));
    }

    /// @dev To one of the pending anchor's edges still ahead: the last second of the delay, the window's first and last
    ///      seconds, or the first second after it.
    function warpToWindowEdge(uint256 seed) external {
        if (shadow.pendingAnchorAt == 0) {
            vm.warp(block.timestamp + 1 hours);
            return;
        }
        uint256[4] memory edges = [shadow.opensAt() - 1, shadow.opensAt(), shadow.closesAt(), shadow.closesAt() + 1];
        uint256 target = edges[_pick(seed, "edge") % 4];
        if (target > block.timestamp) vm.warp(target);
    }

    /// @dev A source that settles near its new level: at the pending anchor or up to 1% beyond it, or short of it but
    ///      still outside the bounds, and the keeper comes back at a time within the pending anchor's window.
    function settleAtPendingAnchor(uint256 seed) external {
        if (shadow.pendingAnchorAt == 0) return;
        uint256 pending = shadow.pendingAnchorPrice;
        bool up = pending > shadow.anchorPrice;
        if (seed % 2 == 0) {
            uint256 beyond = Math.mulDiv(pending, bound(_pick(seed, "beyond"), 0, 0.01e18), WAD);
            SOURCE.setCurrentPrice(up ? pending + beyond : pending - beyond);
        } else {
            uint256 pick = _pick(seed, "short");
            SOURCE.setCurrentPrice(
                up ? bound(pick, shadow.upperBound() + 1, pending) : bound(pick, pending, shadow.lowerBound() - 1)
            );
        }
        uint256 target = bound(_pick(seed, "inWindow"), shadow.opensAt(), shadow.closesAt());
        if (target > block.timestamp) vm.warp(target);
        _update(_caller(seed));
    }

    // ---
    // OPEN CALLS
    // ---

    function updateAnchor(uint256 callerSeed) external {
        _update(_caller(callerSeed));
    }

    /// @dev The keeper's hour: an hour passes, the source mostly steps within 0.04%, then the keeper updates.
    function keeperTick(uint256 seed) external {
        vm.warp(block.timestamp + 1 hours);
        if (seed % 4 != 0) _setSourceAround(seed, 0.9996e18, 1.0004e18);
        _update(_caller(0));
    }

    function _update(address caller) internal {
        uint256 currentPrice = SOURCE.currentPrice();
        TrailingAnchorOracleState memory s = shadow;
        TrailingAnchorOracleUpdate memory u = s.update(currentPrice, SOURCE.isDown(), block.timestamp);
        if (u.revertData.length != 0) {
            vm.prank(caller);
            vm.expectRevert(u.revertData);
            ORACLE.updateAnchor();
            ++refused["update"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        vm.prank(caller);
        TrailingAnchorOracleBase.UpdateOutcome outcome = ORACLE.updateAnchor();
        assertEq(uint8(outcome), uint8(u.outcome), "the outcome the model predicts");
        _checkAnchorMove(s, currentPrice, ORACLE.anchorPrice());
        shadow = u.next;
        if (pricedBefore) {
            (bool pricedAfter, uint256 afterCall) = _price();
            if (!pricedAfter || afterCall != before) ++stoppedPrices;
        }
        ++succeeded["update"];
        if (u.pendingAnchorSet) ++succeeded["pendingAnchor"];
        if (!u.anchorSet && s.pendingAnchorHeld(currentPrice, block.timestamp) && block.timestamp >= s.opensAt()) {
            ++succeeded["pinned"];
        }
    }

    /// @dev Counts a move that is neither a re-anchor nor a drift, and apart from that a move under the floor or over
    ///      the ceiling. A re-anchor needs a waited, unexpired pending anchor and a price outside the bounds on its
    ///      side, and lands on whichever of the two is nearer the anchor, down never under the floor and up never over
    ///      the ceiling. A drift needs a price within the bounds and stays inside the speeds' reach, toward the price.
    ///      The floor and the ceiling hang off `expectedHighWaterMark`, which a drift up raises.
    function _checkAnchorMove(TrailingAnchorOracleState memory s, uint256 currentPrice, uint256 stored) internal {
        if (stored == s.anchorPrice) return;
        uint256 markBefore = expectedHighWaterMark;
        uint256 gapBefore = s.anchorPrice > markBefore ? s.anchorPrice - markBefore : 0;
        uint256 low = Math.min(markBefore - Math.mulDiv(markBefore, s.maxAnchorBelowMark, WAD), s.anchorPrice);
        uint256 high = Math.max(markBefore + Math.mulDiv(markBefore, s.maxAnchorAboveMark, WAD), s.anchorPrice);
        if (stored < low) ++floorBreaches;
        if (_isReanchor(s, currentPrice, stored, low, high)) {
            ++succeeded["reanchor"];
        } else if (_isDrift(s, currentPrice, stored)) {
            ++succeeded["drift"];
            if (stored > s.anchorPrice) expectedHighWaterMark = Math.max(markBefore, stored - gapBefore);
        } else {
            ++strayAnchorMoves;
        }
        uint256 markAfter = expectedHighWaterMark;
        uint256 gapAfter = stored > markAfter ? stored - markAfter : 0;
        if (gapAfter > Math.max(Math.mulDiv(markAfter, s.maxAnchorAboveMark, WAD), gapBefore)) ++ceilingBreaches;
    }

    /// @dev Whether `stored` is a re-anchor: a waited, unexpired pending anchor, a price outside the bounds on its
    ///      side, and the nearer of the two held between `low` and `high`. Counts a re-anchor onto either line.
    function _isReanchor(
        TrailingAnchorOracleState memory s,
        uint256 currentPrice,
        uint256 stored,
        uint256 low,
        uint256 high
    ) internal returns (bool) {
        uint256 opensAt = s.pendingAnchorAt + s.reanchorDelay;
        bool waited =
            s.pendingAnchorAt != 0 && block.timestamp >= opensAt && block.timestamp <= opensAt + s.reanchorWindow;
        bool up = s.pendingAnchorPrice > s.anchorPrice;
        bool heldSide = !s.withinBounds(currentPrice) && (currentPrice > s.anchorPrice) == up;
        uint256 nearer =
            up ? Math.min(s.pendingAnchorPrice, currentPrice) : Math.max(s.pendingAnchorPrice, currentPrice);
        uint256 target = up ? Math.min(nearer, high) : Math.max(nearer, low);
        if (!(waited && heldSide && stored == target)) return false;
        if (target != nearer) ++succeeded[up ? bytes32("ceiling") : bytes32("floor")];
        return true;
    }

    /// @dev Whether `stored` is a drift: toward a price within the bounds, inside the speeds' reach.
    function _isDrift(TrailingAnchorOracleState memory s, uint256 currentPrice, uint256 stored)
        internal
        view
        returns (bool)
    {
        (uint256 lowest, uint256 highest) = s.reach(block.timestamp);
        bool towardPrice = (stored > s.anchorPrice) == (currentPrice > s.anchorPrice)
            && (stored > s.anchorPrice ? stored <= currentPrice : stored >= currentPrice);
        return s.withinBounds(currentPrice) && stored >= lowest && stored <= highest && towardPrice;
    }

    // ---
    // PRICE ACCEPTOR
    // ---

    /// @dev Mostly the exact current price; on one seed in four a range above it, so the refusal runs, and on another
    ///      any price at all.
    function acceptPrice(uint256 seed) external {
        uint256 currentPrice = SOURCE.currentPrice();
        uint256 minPrice = currentPrice;
        uint256 maxPrice = currentPrice;
        if (seed % 4 == 0) {
            minPrice = currentPrice + 1;
            maxPrice = type(uint256).max;
        } else if (seed % 4 == 1) {
            minPrice = 0;
            maxPrice = type(uint256).max;
        }
        bytes memory expected = shadow.acceptRevert(currentPrice, SOURCE.isDown(), minPrice, maxPrice);
        if (expected.length != 0) {
            vm.prank(PRICE_ACCEPTOR);
            vm.expectRevert(expected);
            ORACLE.acceptPrice(minPrice, maxPrice);
            ++refused["accept"];
            return;
        }
        vm.prank(PRICE_ACCEPTOR);
        ORACLE.acceptPrice(minPrice, maxPrice);
        shadow = shadow.accepted(currentPrice, block.timestamp);
        expectedHighWaterMark = currentPrice;
        gapAtParameterChange = 0;
        ++succeeded["accept"];
    }

    // ---
    // MANAGER
    // ---

    function setParameters(uint256 seed) external {
        TrailingAnchorOracleBase.Parameters memory p = _parameters(seed);
        bytes memory expected = TrailingAnchorOracleModel.parametersRevert(p);
        if (expected.length != 0) {
            vm.prank(MANAGER);
            vm.expectRevert(expected);
            ORACLE.setParameters(p);
            ++refused["parameters"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        vm.prank(MANAGER);
        ORACLE.setParameters(p);
        shadow = shadow.withParameters(p);
        uint256 anchor = ORACLE.anchorPrice();
        gapAtParameterChange = anchor > expectedHighWaterMark ? anchor - expectedHighWaterMark : 0;
        (bool pricedAfter, uint256 afterCall) = _price();
        if (pricedBefore && pricedAfter && before != afterCall) ++parameterPriceChanges;
        ++succeeded["parameters"];
    }

    /// @dev Mostly a time up to eight days ahead, past the seven-day cap on some picks; on one pick in four a time
    ///      already passed, which lifts the suspension.
    function setPricingResumesAt(uint256 seed) external {
        uint256 pick = _pick(seed, "suspension");
        uint256 resumesAt = pick % 4 == 0 ? block.timestamp - (pick % 1 days) : block.timestamp + pick % 8 days;
        bytes memory expected = TrailingAnchorOracleModel.pricingResumesAtRevert(resumesAt, block.timestamp);
        if (expected.length != 0) {
            vm.prank(MANAGER);
            vm.expectRevert(expected);
            ORACLE.setPricingResumesAt(uint40(resumesAt));
            ++refused["suspension"];
            return;
        }
        vm.prank(MANAGER);
        ORACLE.setPricingResumesAt(uint40(resumesAt));
        shadow.pricingResumesAt = resumesAt;
        suspensionSetAt = block.timestamp;
        ++succeeded["suspension"];
    }

    // ---
    // HELPERS
    // ---

    /// @dev Parameters around the working defaults. On one pick in eight a single field leaves its range, so the
    ///      validator's refusal runs.
    function _parameters(uint256 seed) internal pure returns (TrailingAnchorOracleBase.Parameters memory p) {
        uint256 pick = _pick(seed, "parameters");
        p.maxPriceAboveAnchor = uint64(bound(_pick(seed, "aboveAnchor"), 0.0001e18, 0.005e18));
        p.maxPriceBelowAnchor = uint64(bound(_pick(seed, "belowAnchor"), 0.0001e18, 0.01e18));
        p.maxAnchorRisePerYear = uint64(bound(_pick(seed, "rise"), 0, 0.2e18));
        p.maxAnchorFallPerYear = uint64(bound(_pick(seed, "fall"), 0, 0.2e18));
        p.maxAnchorBelowMark = uint64(bound(_pick(seed, "belowMark"), 0, 0.05e18));
        p.maxAnchorAboveMark = uint64(bound(_pick(seed, "aboveMark"), 0, 0.01e18));
        p.reanchorDelay = uint40(bound(_pick(seed, "delay"), 1 hours, 2 days));
        p.reanchorWindow = uint40(bound(_pick(seed, "window"), 1 hours, 3 days));
        if (pick % 8 != 0) return p;
        uint256 field = (pick >> 8) % 8;
        if (field == 0) p.maxPriceAboveAnchor = 0;
        else if (field == 1) p.maxPriceBelowAnchor = uint64(WAD);
        else if (field == 2) p.maxPriceAboveAnchor = uint64(WAD);
        else if (field == 3) p.maxAnchorFallPerYear = uint64(WAD + 1);
        else if (field == 4) p.reanchorDelay = 1 hours - 1;
        else if (field == 5) p.reanchorWindow = 0;
        else if (field == 6) p.maxAnchorBelowMark = uint64(WAD);
        else p.maxAnchorAboveMark = uint64(WAD);
    }

    /// @dev Sets the source within `low` and `high` of the anchor, as WAD fractions of it.
    function _setSourceAround(uint256 seed, uint256 low, uint256 high) internal {
        uint256 anchor = shadow.anchorPrice;
        SOURCE.setCurrentPrice(bound(seed, Math.mulDiv(anchor, low, WAD), Math.mulDiv(anchor, high, WAD)));
    }

    /// @dev A hash of the seed for the choices whose edge values the fuzzer's small seeds would hit too often.
    function _pick(uint256 seed, string memory what) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, what)));
    }

    /// @dev Anyone: a fresh address per seed, never a precompile or a cheatcode address.
    function _caller(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("caller", seed)))));
    }

    function _price() internal view returns (bool priced, uint256 value) {
        (bool ok, bytes memory data) = address(ORACLE).staticcall(abi.encodeCall(TrailingAnchorOracleBase.price, ()));
        if (!ok) return (false, 0);
        return (true, abi.decode(data, (uint256)));
    }
}
