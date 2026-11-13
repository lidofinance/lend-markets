// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LIQUIDATION_CURSOR, MAX_LIQUIDATION_INCENTIVE_FACTOR} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";

import {SourceDown} from "./NavSourceMocks.sol";

/// @notice What an anchor oracle stores. The model derives every outcome from these values, the source and the time,
///         never from the oracle's own computed outputs.
struct TrailingAnchorOracleState {
    uint256 anchorPrice;
    uint256 anchorAt;
    uint256 pricingResumesAt;
    uint256 pendingAnchorPrice;
    uint256 pendingAnchorAt;
    uint256 fenceBasePrice;
    uint256 maxPriceAboveAnchor;
    uint256 maxPriceBelowAnchor;
    uint256 maxAnchorRisePerYear;
    uint256 maxAnchorFallPerYear;
    uint256 maxAnchorBelowFenceBase;
    uint256 maxAnchorAboveFenceBase;
    uint256 reanchorDelay;
    uint256 reanchorWindow;
}

/// @notice What one `updateAnchor()` call does: its revert, or the state after it, the outcome it returns, and the
///         events it emits, in the order `AnchorSet`, then `PendingAnchorSet` or `PendingAnchorCleared`, then
///         `AnchorUpdated`.
struct TrailingAnchorOracleUpdate {
    bytes revertData;
    TrailingAnchorOracleState next;
    TrailingAnchorOracleBase.UpdateOutcome outcome;
    bool anchorSet;
    bool pendingAnchorSet;
    bool pendingAnchorCleared;
}

/// @notice The anchor oracle's rules, WAD fixed point, every product rounded down. The unit, invariant and scenario
///         suites share this one copy so their expectations cannot drift apart.
library TrailingAnchorOracleModel {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant PRICE_DECIMALS = 18;
    uint256 internal constant ORACLE_PRICE_DECIMALS = 36;
    uint256 internal constant MIN_REANCHOR_DELAY = 1 hours;
    uint256 internal constant MAX_PRICING_SUSPENSION = 7 days;

    /// @dev Working defaults: a USDY-sized 0.05% bound up and a wider 0.1% down; an anchor that may drift 6% a year up
    ///      and 1% down, a little above a treasury yield and well under it; a floor 1% under the fence base price and a
    ///      ceiling 0.2% over it, inside the 0.26% at which a 98% LLTV position borrowed at the top of the ceiling's
    ///      bounds stops covering its liquidation at the bottom of the floor's; a six-hour delay and a one-day window.
    uint256 internal constant MAX_PRICE_ABOVE_ANCHOR = 0.0005e18;
    uint256 internal constant MAX_PRICE_BELOW_ANCHOR = 0.001e18;
    uint256 internal constant MAX_ANCHOR_RISE_PER_YEAR = 0.06e18;
    uint256 internal constant MAX_ANCHOR_FALL_PER_YEAR = 0.01e18;
    uint256 internal constant MAX_ANCHOR_BELOW_FENCE_BASE = 0.01e18;
    uint256 internal constant MAX_ANCHOR_ABOVE_FENCE_BASE = 0.002e18;
    uint256 internal constant REANCHOR_DELAY = 6 hours;
    uint256 internal constant REANCHOR_WINDOW = 1 days;
    /// @dev The `MAX_LLTV` of the shared suites: zero, so the sizing rule takes any parameters and the suites can move
    ///      the floor and the ceiling out of the way. The sizing rule has tests of its own at a 98% LLTV.
    uint256 internal constant MAX_LLTV = 0;

    // ---
    // DEPLOYMENT
    // ---

    function defaultParameters() internal pure returns (TrailingAnchorOracleBase.Parameters memory) {
        return TrailingAnchorOracleBase.Parameters({
            maxPriceAboveAnchor: uint64(MAX_PRICE_ABOVE_ANCHOR),
            maxPriceBelowAnchor: uint64(MAX_PRICE_BELOW_ANCHOR),
            maxAnchorRisePerYear: uint64(MAX_ANCHOR_RISE_PER_YEAR),
            maxAnchorFallPerYear: uint64(MAX_ANCHOR_FALL_PER_YEAR),
            maxAnchorBelowFenceBase: uint64(MAX_ANCHOR_BELOW_FENCE_BASE),
            maxAnchorAboveFenceBase: uint64(MAX_ANCHOR_ABOVE_FENCE_BASE),
            reanchorDelay: uint40(REANCHOR_DELAY),
            reanchorWindow: uint40(REANCHOR_WINDOW)
        });
    }

    /// @dev The `initialize` call on the working defaults, with a seed range that takes any price.
    function initializeCall(address admin) internal pure returns (bytes memory) {
        return initializeCall(admin, defaultParameters());
    }

    function initializeCall(address admin, TrailingAnchorOracleBase.Parameters memory parameters)
        internal
        pure
        returns (bytes memory)
    {
        return initializeCall(admin, parameters, 0, type(uint256).max);
    }

    function initializeCall(
        address admin,
        TrailingAnchorOracleBase.Parameters memory parameters,
        uint256 minPrice,
        uint256 maxPrice
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(TrailingAnchorOracleBase.initialize, (admin, parameters, minPrice, maxPrice));
    }

    /// @dev 10^(ORACLE_PRICE_DECIMALS + loanDecimals − collateralDecimals − PRICE_DECIMALS).
    function priceScale(uint256 loanDecimals, uint256 collateralDecimals) internal pure returns (uint256) {
        return 10 ** (ORACLE_PRICE_DECIMALS + loanDecimals - collateralDecimals - PRICE_DECIMALS);
    }

    /// @dev The ERC-7201 base slot of the storage namespace `id`, where an adapter's state starts.
    function namespaceSlot(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    // ---
    // STATE
    // ---

    /// @dev The stored state through the oracle's getters.
    function read(TrailingAnchorOracleBase oracle) internal view returns (TrailingAnchorOracleState memory s) {
        s.anchorPrice = oracle.anchorPrice();
        s.anchorAt = oracle.anchorAt();
        s.pricingResumesAt = oracle.pricingResumesAt();
        s.pendingAnchorPrice = oracle.pendingAnchorPrice();
        s.pendingAnchorAt = oracle.pendingAnchorAt();
        s.fenceBasePrice = oracle.fenceBasePrice();
        s.maxPriceAboveAnchor = oracle.maxPriceAboveAnchor();
        s.maxPriceBelowAnchor = oracle.maxPriceBelowAnchor();
        s.maxAnchorRisePerYear = oracle.maxAnchorRisePerYear();
        s.maxAnchorFallPerYear = oracle.maxAnchorFallPerYear();
        s.maxAnchorBelowFenceBase = oracle.maxAnchorBelowFenceBase();
        s.maxAnchorAboveFenceBase = oracle.maxAnchorAboveFenceBase();
        s.reanchorDelay = oracle.reanchorDelay();
        s.reanchorWindow = oracle.reanchorWindow();
    }

    function copy(TrailingAnchorOracleState memory s) internal pure returns (TrailingAnchorOracleState memory) {
        return abi.decode(abi.encode(s), (TrailingAnchorOracleState));
    }

    /// @dev The state after `setParameters(parameters)`: the parameters stored and the pending anchor dropped; the
    ///      anchor and the fence base price stay.
    function withParameters(TrailingAnchorOracleState memory s, TrailingAnchorOracleBase.Parameters memory parameters)
        internal
        pure
        returns (TrailingAnchorOracleState memory next)
    {
        next = copy(s);
        next.maxPriceAboveAnchor = parameters.maxPriceAboveAnchor;
        next.maxPriceBelowAnchor = parameters.maxPriceBelowAnchor;
        next.maxAnchorRisePerYear = parameters.maxAnchorRisePerYear;
        next.maxAnchorFallPerYear = parameters.maxAnchorFallPerYear;
        next.maxAnchorBelowFenceBase = parameters.maxAnchorBelowFenceBase;
        next.maxAnchorAboveFenceBase = parameters.maxAnchorAboveFenceBase;
        next.reanchorDelay = parameters.reanchorDelay;
        next.reanchorWindow = parameters.reanchorWindow;
        next.pendingAnchorPrice = 0;
        next.pendingAnchorAt = 0;
    }

    // ---
    // BOUNDS
    // ---

    /// @dev center × (1 − maxPriceBelowAnchor), rounded down.
    function lowerBound(TrailingAnchorOracleState memory s, uint256 center) internal pure returns (uint256) {
        return Math.mulDiv(center, WAD - s.maxPriceBelowAnchor, WAD);
    }

    /// @dev center × (1 + maxPriceAboveAnchor), rounded down.
    function upperBound(TrailingAnchorOracleState memory s, uint256 center) internal pure returns (uint256) {
        return Math.mulDiv(center, WAD + s.maxPriceAboveAnchor, WAD);
    }

    /// @dev Both edges inclusive.
    function withinBounds(TrailingAnchorOracleState memory s, uint256 center, uint256 value)
        internal
        pure
        returns (bool)
    {
        return value >= lowerBound(s, center) && value <= upperBound(s, center);
    }

    function lowerBound(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return lowerBound(s, s.anchorPrice);
    }

    function upperBound(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return upperBound(s, s.anchorPrice);
    }

    function withinBounds(TrailingAnchorOracleState memory s, uint256 value) internal pure returns (bool) {
        return withinBounds(s, s.anchorPrice, value);
    }

    // ---
    // FLOOR
    // ---

    /// @dev fenceBasePrice × (1 − maxAnchorBelowFenceBase), the distance term rounded down so the floor rounds up.
    function floor(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return s.fenceBasePrice - Math.mulDiv(s.fenceBasePrice, s.maxAnchorBelowFenceBase, WAD);
    }

    /// @dev The lowest anchor an update may set: the floor, or the anchor when it already sits under the floor.
    function lowestAnchor(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return Math.min(floor(s), s.anchorPrice);
    }

    // ---
    // CEILING
    // ---

    /// @dev fenceBasePrice × (1 + maxAnchorAboveFenceBase), the distance term rounded down.
    function ceiling(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return s.fenceBasePrice + Math.mulDiv(s.fenceBasePrice, s.maxAnchorAboveFenceBase, WAD);
    }

    /// @dev The highest anchor a re-anchor may set: the ceiling, or the anchor when it already sits over the ceiling.
    function highestAnchor(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return Math.max(ceiling(s), s.anchorPrice);
    }

    /// @dev The fence base price after a drift to `newAnchorPrice`: max(H, A' − max(A − H, 0)) for a drift up, so
    ///      the new anchor while the anchor sits at or under H, else H raised by the step and the gap a re-anchor left
    ///      above H kept. A drift down leaves it.
    function raisedFenceBasePrice(TrailingAnchorOracleState memory s, uint256 newAnchorPrice)
        internal
        pure
        returns (uint256)
    {
        if (newAnchorPrice <= s.anchorPrice) return s.fenceBasePrice;
        uint256 gap = s.anchorPrice > s.fenceBasePrice ? s.anchorPrice - s.fenceBasePrice : 0;
        return Math.max(s.fenceBasePrice, newAnchorPrice - gap);
    }

    // ---
    // DRIFT
    // ---

    /// @dev e^x − 1 for `x` = rate × elapsed / 365 days, by its first three Taylor terms, each rounded down.
    function compoundedRise(uint256 rate, uint256 elapsed) internal pure returns (uint256) {
        uint256 x = Math.mulDiv(rate, elapsed, YEAR);
        uint256 square = Math.mulDiv(x, x, 2 * WAD);
        return x + square + Math.mulDiv(square, x, 3 * WAD);
    }

    /// @dev The lowest and highest anchor a drift at `time` may set: the fall speed for the time since the anchor last
    ///      moved, the rise speed compounded continuously over it, each term rounded down, the fall term held at the
    ///      anchor price, and the lowest never under `lowestAnchor`.
    function reach(TrailingAnchorOracleState memory s, uint256 time)
        internal
        pure
        returns (uint256 lowest, uint256 highest)
    {
        uint256 elapsed = time - s.anchorAt;
        uint256 fall = Math.min(Math.mulDiv(s.anchorPrice, s.maxAnchorFallPerYear * elapsed, WAD * YEAR), s.anchorPrice);
        lowest = Math.max(s.anchorPrice - fall, lowestAnchor(s));
        highest = s.anchorPrice + Math.mulDiv(s.anchorPrice, compoundedRise(s.maxAnchorRisePerYear, elapsed), WAD);
    }

    /// @dev The anchor a drift toward `currentPrice` at `time` sets: the price held inside the reach.
    function drifted(TrailingAnchorOracleState memory s, uint256 currentPrice, uint256 time)
        internal
        pure
        returns (uint256)
    {
        (uint256 lowest, uint256 highest) = reach(s, time);
        return Math.min(Math.max(currentPrice, lowest), highest);
    }

    // ---
    // PENDING ANCHOR
    // ---

    function opensAt(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return s.pendingAnchorAt + s.reanchorDelay;
    }

    function closesAt(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return s.pendingAnchorAt + s.reanchorDelay + s.reanchorWindow;
    }

    /// @dev A pending anchor is recorded and its window has not closed.
    function pendingAnchorLive(TrailingAnchorOracleState memory s, uint256 time) internal pure returns (bool) {
        return s.pendingAnchorAt != 0 && time <= closesAt(s);
    }

    /// @dev A live pending anchor, with `currentPrice`, outside the bounds, on its side of the anchor.
    function pendingAnchorHeld(TrailingAnchorOracleState memory s, uint256 currentPrice, uint256 time)
        internal
        pure
        returns (bool)
    {
        return pendingAnchorLive(s, time) && (s.pendingAnchorPrice > s.anchorPrice) == (currentPrice > s.anchorPrice);
    }

    /// @dev The anchor a re-anchor sets: the pending anchor or `currentPrice`, whichever is nearer the anchor, up never
    ///      over `highestAnchor` and down never under `lowestAnchor`. The anchor itself when it already sits on the
    ///      ceiling or the floor it moves toward.
    function reanchored(TrailingAnchorOracleState memory s, uint256 currentPrice) internal pure returns (uint256) {
        if (s.pendingAnchorPrice > s.anchorPrice) {
            return Math.min(Math.min(s.pendingAnchorPrice, currentPrice), highestAnchor(s));
        }
        return Math.max(Math.max(s.pendingAnchorPrice, currentPrice), lowestAnchor(s));
    }

    // ---
    // OUTCOMES
    // ---

    /// @dev The revert a read of the source gives, or nothing: `SourceDown` when the source is down.
    function sourceRevert(bool sourceDown) internal pure returns (bytes memory) {
        if (sourceDown) return abi.encodeWithSelector(SourceDown.selector);
        return "";
    }

    /// @dev The revert a read of a Spoke source gives at `time`, or nothing: the source down, then a price stamped
    ///      after `time`, then a price stamped more than `maxPriceAge` before it.
    function sourceRevert(bool sourceDown, uint256 computedAt, uint256 maxPriceAge, uint256 time)
        internal
        pure
        returns (bytes memory)
    {
        if (sourceDown) return abi.encodeWithSelector(SourceDown.selector);
        if (computedAt > time) {
            return abi.encodeWithSelector(CentrifugeNavOracle.PriceFromFuture.selector, uint64(computedAt));
        }
        if (time - computedAt > maxPriceAge) {
            return abi.encodeWithSelector(CentrifugeNavOracle.StalePrice.selector, uint64(computedAt));
        }
        return "";
    }

    /// @dev `priceRevert` for a source that reverts only when it is down.
    function priceRevert(TrailingAnchorOracleState memory s, uint256 currentPrice, bool sourceDown, uint256 time)
        internal
        pure
        returns (bytes memory)
    {
        return priceRevert(s, currentPrice, sourceRevert(sourceDown), time);
    }

    /// @dev The revert `price()` gives, or nothing: the suspension, then the source's own revert `sourceError`, a zero
    ///      price and the bounds.
    function priceRevert(
        TrailingAnchorOracleState memory s,
        uint256 currentPrice,
        bytes memory sourceError,
        uint256 time
    ) internal pure returns (bytes memory) {
        if (time < s.pricingResumesAt) {
            return abi.encodeWithSelector(
                TrailingAnchorOracleBase.PricingSuspended.selector, uint40(s.pricingResumesAt)
            );
        }
        if (sourceError.length != 0) return sourceError;
        if (currentPrice == 0) return abi.encodeWithSelector(TrailingAnchorOracleBase.ZeroPrice.selector);
        if (withinBounds(s, currentPrice)) return "";
        return abi.encodeWithSelector(
            TrailingAnchorOracleBase.PriceOutOfBounds.selector, currentPrice, lowerBound(s), upperBound(s)
        );
    }

    /// @dev What `updateAnchor()` does at `time`:
    ///      - a price within the anchor's bounds drifts the anchor toward it and drops the pending anchor;
    ///      - outside them, a held pending anchor holds the anchor still until it opens, then moves it onto the pending
    ///        anchor or the price, whichever is nearer the anchor, and is dropped if the price is within the new
    ///        bounds;
    ///      - an open pending anchor that would take the anchor under the floor or over the ceiling moves it onto that
    ///        line, and one with the anchor already there changes nothing;
    ///      - any other price outside the bounds is recorded as the pending anchor.
    ///      A drift up raises the fence base price by `raisedFenceBasePrice`, a re-anchor leaves it, and every call
    ///      that does not revert returns the outcome of its case.
    function update(TrailingAnchorOracleState memory s, uint256 currentPrice, bool sourceDown, uint256 time)
        internal
        pure
        returns (TrailingAnchorOracleUpdate memory u)
    {
        return update(s, currentPrice, sourceRevert(sourceDown), time);
    }

    /// @dev `update` for a source whose read reverts with `sourceError`, or does not when it is empty: the update then
    ///      reverts with it and changes nothing.
    function update(TrailingAnchorOracleState memory s, uint256 currentPrice, bytes memory sourceError, uint256 time)
        internal
        pure
        returns (TrailingAnchorOracleUpdate memory u)
    {
        u.next = copy(s);
        if (sourceError.length != 0) {
            u.revertData = sourceError;
            return u;
        }
        if (currentPrice == 0) {
            u.revertData = abi.encodeWithSelector(TrailingAnchorOracleBase.ZeroPrice.selector);
            return u;
        }

        TrailingAnchorOracleState memory n = u.next;
        if (withinBounds(s, currentPrice)) {
            uint256 newAnchorPrice = drifted(s, currentPrice, time);
            if (newAnchorPrice != s.anchorPrice) {
                n.fenceBasePrice = raisedFenceBasePrice(s, newAnchorPrice);
                _setAnchor(n, u, newAnchorPrice, time);
            }
            _dropPendingAnchor(n, u);
            u.outcome = TrailingAnchorOracleBase.UpdateOutcome.WithinBounds;
            return u;
        }
        if (!pendingAnchorHeld(s, currentPrice, time)) {
            _recordPendingAnchor(n, u, currentPrice, time);
            u.outcome = TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorRecorded;
            return u;
        }
        if (time < opensAt(s)) {
            u.outcome = TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorHeld;
            return u;
        }
        uint256 reanchorPrice = reanchored(s, currentPrice);
        if (reanchorPrice == s.anchorPrice) {
            u.outcome = s.pendingAnchorPrice > s.anchorPrice
                ? TrailingAnchorOracleBase.UpdateOutcome.AnchorOnCeiling
                : TrailingAnchorOracleBase.UpdateOutcome.AnchorOnFloor;
            return u;
        }
        _setAnchor(n, u, reanchorPrice, time);
        if (withinBounds(n, currentPrice)) _dropPendingAnchor(n, u);
        else _recordPendingAnchor(n, u, currentPrice, time);
        u.outcome = TrailingAnchorOracleBase.UpdateOutcome.PendingAnchorApplied;
    }

    /// @dev Records `currentPrice` as the pending anchor of `n` at `time`, and marks the update.
    function _recordPendingAnchor(
        TrailingAnchorOracleState memory n,
        TrailingAnchorOracleUpdate memory u,
        uint256 currentPrice,
        uint256 time
    ) private pure {
        n.pendingAnchorPrice = currentPrice;
        n.pendingAnchorAt = time;
        u.pendingAnchorSet = true;
    }

    /// @dev Sets the anchor of `n` by an update, and marks the update. The fence base price is the caller's.
    function _setAnchor(
        TrailingAnchorOracleState memory n,
        TrailingAnchorOracleUpdate memory u,
        uint256 newAnchorPrice,
        uint256 time
    ) private pure {
        n.anchorPrice = newAnchorPrice;
        n.anchorAt = time;
        u.anchorSet = true;
    }

    /// @dev Drops the pending anchor of `n`, if there is one, and marks the update.
    function _dropPendingAnchor(TrailingAnchorOracleState memory n, TrailingAnchorOracleUpdate memory u) private pure {
        if (n.pendingAnchorAt == 0) return;
        n.pendingAnchorPrice = 0;
        n.pendingAnchorAt = 0;
        u.pendingAnchorCleared = true;
    }

    /// @dev The revert `acceptPrice(minPrice, maxPrice)` gives a price acceptor, or nothing: the source, the range and
    ///      a zero price.
    function acceptRevert(
        TrailingAnchorOracleState memory s,
        uint256 currentPrice,
        bool sourceDown,
        uint256 minPrice,
        uint256 maxPrice
    ) internal pure returns (bytes memory) {
        return acceptRevert(s, currentPrice, sourceRevert(sourceDown), minPrice, maxPrice);
    }

    /// @dev `acceptRevert` for a source whose read reverts with `sourceError`, or does not when it is empty.
    function acceptRevert(
        TrailingAnchorOracleState memory s,
        uint256 currentPrice,
        bytes memory sourceError,
        uint256 minPrice,
        uint256 maxPrice
    ) internal pure returns (bytes memory) {
        if (sourceError.length != 0) return sourceError;
        if (currentPrice < minPrice || currentPrice > maxPrice) {
            return
                abi.encodeWithSelector(
                    TrailingAnchorOracleBase.UnexpectedPrice.selector, currentPrice, minPrice, maxPrice
                );
        }
        if (currentPrice == 0) return abi.encodeWithSelector(TrailingAnchorOracleBase.ZeroPrice.selector);
        return "";
    }

    /// @dev The state after a successful `acceptPrice()` at `time`: the fence base price restarts at the price.
    function accepted(TrailingAnchorOracleState memory s, uint256 currentPrice, uint256 time)
        internal
        pure
        returns (TrailingAnchorOracleState memory next)
    {
        next = copy(s);
        next.anchorPrice = currentPrice;
        next.anchorAt = time;
        next.fenceBasePrice = currentPrice;
        next.pendingAnchorPrice = 0;
        next.pendingAnchorAt = 0;
    }

    /// @dev `InvalidParameters()`, or nothing, for an oracle sized for `MAX_LLTV`.
    function parametersRevert(TrailingAnchorOracleBase.Parameters memory p) internal pure returns (bytes memory) {
        return parametersRevert(p, MAX_LLTV);
    }

    /// @dev `InvalidParameters()`, or nothing: each bound above zero and below a whole price, each speed at most a
    ///      whole price a year, `maxAnchorBelowFenceBase` and `maxAnchorAboveFenceBase` below a whole price, a delay
    ///      of at least an hour in which each speed covers at most its bound, a window above zero, and the sizing rule
    ///      at `maxLltv`.
    function parametersRevert(TrailingAnchorOracleBase.Parameters memory p, uint256 maxLltv)
        internal
        pure
        returns (bytes memory)
    {
        bool valid = p.maxPriceAboveAnchor != 0 && p.maxPriceBelowAnchor != 0 && p.maxPriceAboveAnchor < WAD
            && p.maxPriceBelowAnchor < WAD && p.maxAnchorRisePerYear <= WAD && p.maxAnchorFallPerYear <= WAD
            && p.maxAnchorBelowFenceBase < WAD && p.maxAnchorAboveFenceBase < WAD
            && p.reanchorDelay >= MIN_REANCHOR_DELAY && p.reanchorWindow != 0
            && compoundedRise(p.maxAnchorRisePerYear, p.reanchorDelay) <= p.maxPriceAboveAnchor
            && uint256(p.reanchorDelay) * p.maxAnchorFallPerYear <= uint256(p.maxPriceBelowAnchor) * YEAR
            && sized(p, maxLltv);
        if (valid) return "";
        return abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidParameters.selector);
    }

    /// @dev The sizing rule from the spec formula and not from the contract: (1 − maxAnchorBelowFenceBase)(1 −
    ///      maxPriceBelowAnchor) ≥ LLTV × LIF × (1 + maxAnchorAboveFenceBase)(1 + maxPriceAboveAnchor). LIF is the
    ///      integer incentive that the core applies in a liquidation, `min(MAX_LIQUIDATION_INCENTIVE_FACTOR, WAD /
    ///      (WAD − LIQUIDATION_CURSOR × (WAD − LLTV)))` with each division rounded down. The rest is multiplied
    /// through
    ///      in whole numbers, so nothing else is rounded.
    function sized(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv) internal pure returns (bool) {
        uint256 incentive =
            Math.min(MAX_LIQUIDATION_INCENTIVE_FACTOR, WAD * WAD / (WAD - LIQUIDATION_CURSOR * (WAD - lltv) / WAD));
        uint256 room = (WAD - p.maxAnchorBelowFenceBase) * (WAD - p.maxPriceBelowAnchor);
        uint256 reach = (WAD + p.maxAnchorAboveFenceBase) * (WAD + p.maxPriceAboveAnchor);
        return room * WAD * WAD >= lltv * incentive * reach;
    }

    /// @dev `InvalidPricingResumesAt(resumesAt)` when it ends more than `MAX_PRICING_SUSPENSION` after `time`.
    function pricingResumesAtRevert(uint256 resumesAt, uint256 time) internal pure returns (bytes memory) {
        if (resumesAt <= time + MAX_PRICING_SUSPENSION) return "";
        return abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidPricingResumesAt.selector, resumesAt);
    }
}
