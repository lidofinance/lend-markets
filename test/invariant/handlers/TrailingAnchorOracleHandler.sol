// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TrailingAnchorOracleBase} from "../../../src/oracle/TrailingAnchorOracleBase.sol";

import {TrailingAnchorOracleModel, TrailingAnchorOracleState} from "../../setup/TrailingAnchorOracleModel.sol";
import {INavSourceMock} from "../../setup/NavSourceMocks.sol";

/// @notice Drives one anchor oracle through every state-changing entry point: the source and time move, anyone calls
///         `updateAnchor()`, the price acceptor accepts prices in a range, and the manager changes the five parameters.
/// @dev The handler keeps a shadow of the stored state and updates it by the rules only. Before each call it predicts,
///      from the shadow, whether the call succeeds and otherwise the exact revert data, so a call the rules allow
///      reverts the run and a call they refuse must revert with the predicted error. Ghost counters record what the
///      suite's invariants read.
contract TrailingAnchorOracleHandler is Test {
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    TrailingAnchorOracleBase public immutable ORACLE;
    INavSourceMock internal immutable SOURCE;
    address internal immutable MANAGER;
    address internal immutable PRICE_ACCEPTOR;

    TrailingAnchorOracleState internal shadow;

    /// @dev Ghost violations: an update or a parameter change that changed a returned price, and an update that left
    ///      the stored anchor outside the reach of the one before.
    uint256 public openCallPriceChanges;
    uint256 public parameterPriceChanges;
    uint256 public oversizedUpdateSteps;

    /// @dev The anchor's reach since the last seed or acceptance: the highest and lowest prices the updates since then
    ///      could compound to, each at the speeds and for the time it counted.
    uint256 public highestReachable;
    uint256 public lowestReachable;

    /// @dev Open updates that moved the anchor since the source last took a new value, counted from the world's side
    ///      rather than the shadow's.
    uint256 public updatesSinceSourceChange;

    /// @dev Coverage counters, logged after the campaign.
    mapping(bytes32 action => uint256) public succeeded;
    mapping(bytes32 action => uint256) public refused;

    constructor(TrailingAnchorOracleBase oracle, INavSourceMock source, address manager, address priceAcceptor) {
        ORACLE = oracle;
        SOURCE = source;
        MANAGER = manager;
        PRICE_ACCEPTOR = priceAcceptor;
        shadow = TrailingAnchorOracleModel.read(oracle);
        _resetReach();
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

    /// @dev Moves the source anywhere within 1% of the anchor, past both bounds.
    function moveSource(uint256 seed) external {
        uint256 anchor = shadow.anchorPrice;
        _setSource(bound(seed, anchor * 0.99e18 / WAD, anchor * 1.01e18 / WAD));
    }

    /// @dev Keeps the source within 0.04% of the anchor, inside the default bounds.
    function stepSource(uint256 seed) external {
        uint256 anchor = shadow.anchorPrice;
        _setSource(bound(seed, anchor * 0.9996e18 / WAD, anchor * 1.0004e18 / WAD));
    }

    /// @dev Takes the source down on one pick in eight and brings it back otherwise, so outages stay short. The pick is
    ///      a hash of the seed, since the fuzzer favours small seeds and zero would keep the source down.
    function setSourceDown(uint256 seed) external {
        SOURCE.setDown(_pick(seed, "down") % 8 == 0);
    }

    /// @dev Up to 15 days at once, across the lifetime.
    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 15 days));
    }

    // ---
    // OPEN CALLS
    // ---

    function updateAnchor(uint256 callerSeed) external {
        _update(_caller(callerSeed));
    }

    /// @dev The keeper's day: a day passes, the source mostly steps within 0.04%, then the keeper updates.
    function keeperDay(uint256 seed) external {
        vm.warp(block.timestamp + 1 days);
        if (seed % 4 != 0) {
            uint256 anchor = shadow.anchorPrice;
            _setSource(bound(seed, anchor * 0.9996e18 / WAD, anchor * 1.0004e18 / WAD));
        }
        _update(_caller(0));
    }

    function _update(address caller) internal {
        uint256 currentPrice = SOURCE.currentPrice();
        bytes memory expected = shadow.updateRevert(currentPrice, SOURCE.isDown(), block.timestamp);
        if (expected.length != 0) {
            vm.prank(caller);
            vm.expectRevert(expected);
            ORACLE.updateAnchor();
            ++refused["update"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        (uint256 lowest, uint256 highest) = shadow.reach(block.timestamp);
        uint256 counted = shadow.countedTime(block.timestamp);
        vm.prank(caller);
        ORACLE.updateAnchor();
        uint256 stored = ORACLE.anchorPrice();
        if (stored < lowest || stored > highest) ++oversizedUpdateSteps;
        shadow.anchorPrice = shadow.nextAnchor(currentPrice, block.timestamp);
        shadow.anchorAt = block.timestamp;
        shadow.sourcePrice = currentPrice;
        ++updatesSinceSourceChange;
        highestReachable += Math.mulDiv(highestReachable, shadow.maxAnchorRise * counted, WAD * YEAR);
        lowestReachable -= Math.mulDiv(lowestReachable, shadow.maxAnchorFall * counted, WAD * YEAR);
        _countOpenCallChange(pricedBefore, before);
        ++succeeded["update"];
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
        bytes memory expected =
            TrailingAnchorOracleModel.acceptRevert(currentPrice, SOURCE.isDown(), minPrice, maxPrice);
        if (expected.length != 0) {
            vm.prank(PRICE_ACCEPTOR);
            vm.expectRevert(expected);
            ORACLE.acceptPrice(minPrice, maxPrice);
            ++refused["accept"];
            return;
        }
        vm.prank(PRICE_ACCEPTOR);
        ORACLE.acceptPrice(minPrice, maxPrice);
        shadow.anchorPrice = currentPrice;
        shadow.anchorAt = block.timestamp;
        shadow.sourcePrice = currentPrice;
        _resetReach();
        ++succeeded["accept"];
    }

    // ---
    // MANAGER
    // ---

    function setMaxPriceIncrease(uint256 seed) external {
        uint256 value = _fraction(seed);
        bytes memory expected = TrailingAnchorOracleModel.maxPriceIncreaseRevert(value);
        if (expected.length != 0) {
            vm.prank(MANAGER);
            vm.expectRevert(expected);
            ORACLE.setMaxPriceIncrease(value);
            ++refused["maxPriceIncrease"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        vm.prank(MANAGER);
        ORACLE.setMaxPriceIncrease(value);
        shadow.maxPriceIncrease = value;
        _countParameterChange(pricedBefore, before);
        ++succeeded["maxPriceIncrease"];
    }

    function setMaxPriceDecrease(uint256 seed) external {
        uint256 value = _fraction(seed);
        bytes memory expected = TrailingAnchorOracleModel.maxPriceDecreaseRevert(value);
        if (expected.length != 0) {
            vm.prank(MANAGER);
            vm.expectRevert(expected);
            ORACLE.setMaxPriceDecrease(value);
            ++refused["maxPriceDecrease"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        vm.prank(MANAGER);
        ORACLE.setMaxPriceDecrease(value);
        shadow.maxPriceDecrease = value;
        _countParameterChange(pricedBefore, before);
        ++succeeded["maxPriceDecrease"];
    }

    /// @dev Mostly an hour up to the cap. On one pick in sixteen zero or the cap itself, so the validator's refusal
    ///      runs, and on another a few seconds, so the lifetime caps the time an update counts.
    function setAnchorLifetime(uint256 seed) external {
        uint256 pick = _pick(seed, "lifetime");
        uint256 value = bound(pick, 1 hours, TrailingAnchorOracleModel.MAX_ANCHOR_LIFETIME - 1);
        if (pick % 16 == 0) value = pick % 32 == 0 ? 0 : TrailingAnchorOracleModel.MAX_ANCHOR_LIFETIME;
        if (pick % 16 == 1) value = bound(pick, 1, 1 minutes);
        bytes memory expected = TrailingAnchorOracleModel.anchorLifetimeRevert(value);
        if (expected.length != 0) {
            vm.prank(MANAGER);
            vm.expectRevert(expected);
            ORACLE.setAnchorLifetime(value);
            ++refused["anchorLifetime"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        vm.prank(MANAGER);
        ORACLE.setAnchorLifetime(value);
        shadow.anchorLifetime = value;
        _countParameterChange(pricedBefore, before);
        ++succeeded["anchorLifetime"];
    }

    function setMaxAnchorRise(uint256 seed) external {
        uint256 value = _speed(seed);
        bytes memory expected = TrailingAnchorOracleModel.maxAnchorRiseRevert(value);
        if (expected.length != 0) {
            vm.prank(MANAGER);
            vm.expectRevert(expected);
            ORACLE.setMaxAnchorRise(value);
            ++refused["maxAnchorRise"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        vm.prank(MANAGER);
        ORACLE.setMaxAnchorRise(value);
        shadow.maxAnchorRise = value;
        _countParameterChange(pricedBefore, before);
        ++succeeded["maxAnchorRise"];
    }

    function setMaxAnchorFall(uint256 seed) external {
        uint256 value = _speed(seed);
        bytes memory expected = TrailingAnchorOracleModel.maxAnchorFallRevert(value);
        if (expected.length != 0) {
            vm.prank(MANAGER);
            vm.expectRevert(expected);
            ORACLE.setMaxAnchorFall(value);
            ++refused["maxAnchorFall"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        vm.prank(MANAGER);
        ORACLE.setMaxAnchorFall(value);
        shadow.maxAnchorFall = value;
        _countParameterChange(pricedBefore, before);
        ++succeeded["maxAnchorFall"];
    }

    // ---
    // HELPERS
    // ---

    /// @dev Any fraction up to 2%; on one seed in eight zero or a whole price, so the validator's refusal runs.
    function _fraction(uint256 seed) internal pure returns (uint256) {
        if (seed % 8 == 0) return seed % 16 == 0 ? 0 : WAD;
        return bound(seed, 1, 0.02e18);
    }

    /// @dev Mostly 1% to 20% a year. On one pick in sixteen zero, the speed that stops a direction, and on another just
    ///      over a whole price a year, so the validator's refusal runs. A speed of a few wei a year would round every
    ///      move to nothing, so it is left out.
    function _speed(uint256 seed) internal pure returns (uint256) {
        uint256 pick = _pick(seed, "speed");
        if (pick % 16 == 0) return 0;
        if (pick % 16 == 1) return WAD + 1;
        return bound(pick, 0.01e18, 0.2e18);
    }

    /// @dev A hash of the seed for the choices whose edge values the fuzzer's small seeds would hit too often.
    function _pick(uint256 seed, string memory what) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, what)));
    }

    /// @dev Sets the source; a value other than the one it holds counts as a source change.
    function _setSource(uint256 currentPrice) internal {
        if (currentPrice != SOURCE.currentPrice()) updatesSinceSourceChange = 0;
        SOURCE.setCurrentPrice(currentPrice);
    }

    function _resetReach() internal {
        highestReachable = shadow.anchorPrice;
        lowestReachable = shadow.anchorPrice;
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

    /// @dev An update may bring a price back inside the bounds, but a price that returned before must return the same
    ///      value after: the new anchor lies between the old one and the current price.
    function _countOpenCallChange(bool pricedBefore, uint256 before) internal {
        if (!pricedBefore) return;
        (bool pricedAfter, uint256 afterCall) = _price();
        if (!pricedAfter || before != afterCall) ++openCallPriceChanges;
    }

    /// @dev A parameter change may move a revert boundary, but never a returned value.
    function _countParameterChange(bool pricedBefore, uint256 before) internal {
        (bool pricedAfter, uint256 afterCall) = _price();
        if (!pricedBefore || !pricedAfter) return;
        if (before != afterCall) ++parameterPriceChanges;
    }
}
