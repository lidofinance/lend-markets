// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";

import {SourceDown} from "./NavSourceMocks.sol";

/// @notice What an anchor oracle stores. The model derives every outcome from these values, the source and the time,
///         never from the oracle's own computed outputs.
struct TrailingAnchorOracleState {
    uint256 anchorPrice;
    uint256 anchorAt;
    uint256 sourcePrice;
    uint256 maxPriceIncrease;
    uint256 maxPriceDecrease;
    uint256 anchorLifetime;
    uint256 maxAnchorRise;
    uint256 maxAnchorFall;
}

/// @notice The anchor oracle's rules, WAD fixed point, every product rounded down. The unit, invariant and scenario
///         suites share this one copy so their expectations cannot drift apart.
library TrailingAnchorOracleModel {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant PRICE_DECIMALS = 18;
    uint256 internal constant ORACLE_PRICE_DECIMALS = 36;
    uint256 internal constant MAX_ANCHOR_LIFETIME = 30 days;

    /// @dev Working defaults: a USDY-sized 0.05% bound up and a wider 0.1% down, a 10-day lifetime, and an anchor that
    ///      may rise 6% and fall 1% a year, a little above a treasury yield and well under it.
    uint256 internal constant MAX_PRICE_INCREASE = 0.0005e18;
    uint256 internal constant MAX_PRICE_DECREASE = 0.001e18;
    uint256 internal constant ANCHOR_LIFETIME = 10 days;
    uint256 internal constant MAX_ANCHOR_RISE = 0.06e18;
    uint256 internal constant MAX_ANCHOR_FALL = 0.01e18;

    /// @dev The `initialize` call on the working defaults.
    function initializeCall(address admin) internal pure returns (bytes memory) {
        return initializeCall(
            admin, MAX_PRICE_INCREASE, MAX_PRICE_DECREASE, ANCHOR_LIFETIME, MAX_ANCHOR_RISE, MAX_ANCHOR_FALL
        );
    }

    function initializeCall(
        address admin,
        uint256 maxPriceIncrease,
        uint256 maxPriceDecrease,
        uint256 anchorLifetime,
        uint256 maxAnchorRise,
        uint256 maxAnchorFall
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            TrailingAnchorOracleBase.initialize,
            (admin, maxPriceIncrease, maxPriceDecrease, anchorLifetime, maxAnchorRise, maxAnchorFall)
        );
    }

    /// @dev 10^(ORACLE_PRICE_DECIMALS + loanDecimals − collateralDecimals − PRICE_DECIMALS).
    function priceScale(uint256 loanDecimals, uint256 collateralDecimals) internal pure returns (uint256) {
        return 10 ** (ORACLE_PRICE_DECIMALS + loanDecimals - collateralDecimals - PRICE_DECIMALS);
    }

    /// @dev The ERC-7201 base slot of the storage namespace `id`, where an adapter's state starts.
    function namespaceSlot(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    /// @dev The stored state through the oracle's getters.
    function read(TrailingAnchorOracleBase oracle) internal view returns (TrailingAnchorOracleState memory s) {
        s.anchorPrice = oracle.anchorPrice();
        s.anchorAt = oracle.anchorAt();
        s.sourcePrice = oracle.sourcePrice();
        s.maxPriceIncrease = oracle.maxPriceIncrease();
        s.maxPriceDecrease = oracle.maxPriceDecrease();
        s.anchorLifetime = oracle.anchorLifetime();
        s.maxAnchorRise = oracle.maxAnchorRise();
        s.maxAnchorFall = oracle.maxAnchorFall();
    }

    /// @dev anchorPrice × (1 − maxPriceDecrease), rounded down.
    function lowerBound(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return Math.mulDiv(s.anchorPrice, WAD - s.maxPriceDecrease, WAD);
    }

    /// @dev anchorPrice × (1 + maxPriceIncrease), rounded down.
    function upperBound(TrailingAnchorOracleState memory s) internal pure returns (uint256) {
        return Math.mulDiv(s.anchorPrice, WAD + s.maxPriceIncrease, WAD);
    }

    /// @dev Both edges inclusive.
    function withinBounds(TrailingAnchorOracleState memory s, uint256 currentPrice) internal pure returns (bool) {
        return currentPrice >= lowerBound(s) && currentPrice <= upperBound(s);
    }

    /// @dev Older than the lifetime at `time`; exactly the lifetime old is still fresh.
    function isStale(TrailingAnchorOracleState memory s, uint256 time) internal pure returns (bool) {
        return time - s.anchorAt > s.anchorLifetime;
    }

    /// @dev The time an update at `time` counts: since the anchor last moved. An update on a stale anchor is refused,
    ///      so the time it counts never passes the lifetime.
    function countedTime(TrailingAnchorOracleState memory s, uint256 time) internal pure returns (uint256) {
        return time - s.anchorAt;
    }

    /// @dev The lowest and highest anchor an update at `time` may set: the anchor less the fall speed, and plus the
    ///      rise speed, for the counted time, each term rounded down so the reach rounds toward the anchor.
    function reach(TrailingAnchorOracleState memory s, uint256 time)
        internal
        pure
        returns (uint256 lowest, uint256 highest)
    {
        uint256 t = countedTime(s, time);
        lowest = s.anchorPrice - Math.mulDiv(s.anchorPrice, s.maxAnchorFall * t, WAD * YEAR);
        highest = s.anchorPrice + Math.mulDiv(s.anchorPrice, s.maxAnchorRise * t, WAD * YEAR);
    }

    /// @dev The anchor an update at `time` sets: the current price, held inside the reach.
    function nextAnchor(TrailingAnchorOracleState memory s, uint256 currentPrice, uint256 time)
        internal
        pure
        returns (uint256)
    {
        (uint256 lowest, uint256 highest) = reach(s, time);
        return Math.min(Math.max(currentPrice, lowest), highest);
    }

    /// @dev The revert `price()` gives, or nothing: the lifetime before the source is read, then the source, a zero
    ///      price and the bounds.
    function priceRevert(TrailingAnchorOracleState memory s, uint256 currentPrice, bool sourceDown, uint256 time)
        internal
        pure
        returns (bytes memory)
    {
        if (isStale(s, time)) return _staleRevert(s);
        if (sourceDown) return abi.encodeWithSelector(SourceDown.selector);
        if (currentPrice == 0) return abi.encodeWithSelector(TrailingAnchorOracleBase.ZeroPrice.selector);
        return _boundsRevert(s, currentPrice);
    }

    /// @dev The revert `updateAnchor()` gives, or nothing: the lifetime before the source is read, then the source, a
    ///      zero price, the current price the anchor last moved on, and an anchor the update would leave where it is.
    ///      The bounds do not stop an update.
    function updateRevert(TrailingAnchorOracleState memory s, uint256 currentPrice, bool sourceDown, uint256 time)
        internal
        pure
        returns (bytes memory)
    {
        if (isStale(s, time)) return _staleRevert(s);
        if (sourceDown) return abi.encodeWithSelector(SourceDown.selector);
        if (currentPrice == 0) return abi.encodeWithSelector(TrailingAnchorOracleBase.ZeroPrice.selector);
        if (currentPrice == s.sourcePrice) {
            return abi.encodeWithSelector(TrailingAnchorOracleBase.SourceUnchanged.selector, currentPrice);
        }
        if (nextAnchor(s, currentPrice, time) == s.anchorPrice) {
            return abi.encodeWithSelector(TrailingAnchorOracleBase.AnchorUnchanged.selector, currentPrice);
        }
        return "";
    }

    /// @dev The revert `acceptPrice(minPrice, maxPrice)` gives a price acceptor, or nothing: the source, the range
    ///      and a zero price.
    function acceptRevert(uint256 currentPrice, bool sourceDown, uint256 minPrice, uint256 maxPrice)
        internal
        pure
        returns (bytes memory)
    {
        if (sourceDown) return abi.encodeWithSelector(SourceDown.selector);
        if (currentPrice < minPrice || currentPrice > maxPrice) {
            return
                abi.encodeWithSelector(
                    TrailingAnchorOracleBase.UnexpectedPrice.selector, currentPrice, minPrice, maxPrice
                );
        }
        if (currentPrice == 0) return abi.encodeWithSelector(TrailingAnchorOracleBase.ZeroPrice.selector);
        return "";
    }

    function maxPriceIncreaseRevert(uint256 value) internal pure returns (bytes memory) {
        if (value == 0 || value >= WAD) {
            return abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceIncrease.selector, value);
        }
        return "";
    }

    function maxPriceDecreaseRevert(uint256 value) internal pure returns (bytes memory) {
        if (value == 0 || value >= WAD) {
            return abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxPriceDecrease.selector, value);
        }
        return "";
    }

    function anchorLifetimeRevert(uint256 value) internal pure returns (bytes memory) {
        if (value == 0 || value >= MAX_ANCHOR_LIFETIME) {
            return abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidAnchorLifetime.selector, value);
        }
        return "";
    }

    /// @dev Zero is allowed: it stops open updates in that direction.
    function maxAnchorRiseRevert(uint256 value) internal pure returns (bytes memory) {
        if (value > WAD) return abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxAnchorRise.selector, value);
        return "";
    }

    /// @dev Zero is allowed: it stops open updates in that direction.
    function maxAnchorFallRevert(uint256 value) internal pure returns (bytes memory) {
        if (value > WAD) return abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxAnchorFall.selector, value);
        return "";
    }

    function _staleRevert(TrailingAnchorOracleState memory s) private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            TrailingAnchorOracleBase.StaleAnchor.selector, uint40(s.anchorAt), uint40(s.anchorLifetime)
        );
    }

    function _boundsRevert(TrailingAnchorOracleState memory s, uint256 currentPrice)
        private
        pure
        returns (bytes memory)
    {
        if (withinBounds(s, currentPrice)) return "";
        return abi.encodeWithSelector(
            TrailingAnchorOracleBase.PriceOutOfBounds.selector, currentPrice, lowerBound(s), upperBound(s)
        );
    }
}
