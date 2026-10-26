// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";

import {TrailingAnchorOracleModel, TrailingAnchorOracleState} from "../setup/TrailingAnchorOracleModel.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {CentrifugeNavOracleFixture, NavOracleFixture, UsdyNavOracleFixture} from "../setup/NavOracleFixtures.sol";

import {TrailingAnchorOracleHandler} from "./handlers/TrailingAnchorOracleHandler.sol";

/// @notice Stateful invariants of one anchor oracle under any sequence of source moves, time, open updates, price
///         acceptances and manager calls, run once through each adapter. The oracle runs alone: the core only reads
///         `price()`, so a market adds no state the oracle can see.
/// @dev The handler's shadow follows the write rules, so `invariant_storedStateMatchesModel` pins the stored values and
///      every other invariant recomputes from them with `TrailingAnchorOracleModel`.
abstract contract TrailingAnchorOracleInvariantTest is NavOracleFixture {
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant START = 1_760_000_000;
    uint256 internal constant WAD = 1e18;

    TrailingAnchorOracleBase internal oracle;
    TrailingAnchorOracleHandler internal handler;
    /// @dev Recomputed from the token decimals, not read from the oracle.
    uint256 internal priceScale;

    function setUp() public {
        vm.warp(START);
        _setUpSource();
        source.setCurrentPrice(1.112233445566778899e18);
        MockERC20 loan = new MockERC20("USD Coin", "USDC", 6);
        priceScale = TrailingAnchorOracleModel.priceScale(6, IERC20Metadata(collateralToken).decimals());
        oracle = _deployOracle(address(loan), address(this), TrailingAnchorOracleModel.initializeCall(address(this)));

        address manager = makeAddr("manager");
        address priceAcceptor = makeAddr("priceAcceptor");
        oracle.grantRole(oracle.MANAGER_ROLE(), manager);
        oracle.grantRole(oracle.PRICE_ACCEPTOR_ROLE(), priceAcceptor);
        handler = new TrailingAnchorOracleHandler(oracle, source, manager, priceAcceptor);

        // Weighted: small source steps, the keeper's day and updates appear more than once, since an update needs a
        // price away from the anchor and time since the anchor moved to succeed.
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = TrailingAnchorOracleHandler.moveSource.selector;
        selectors[1] = TrailingAnchorOracleHandler.stepSource.selector;
        selectors[2] = TrailingAnchorOracleHandler.stepSource.selector;
        selectors[3] = TrailingAnchorOracleHandler.setSourceDown.selector;
        selectors[4] = TrailingAnchorOracleHandler.warp.selector;
        selectors[5] = TrailingAnchorOracleHandler.updateAnchor.selector;
        selectors[6] = TrailingAnchorOracleHandler.updateAnchor.selector;
        selectors[7] = TrailingAnchorOracleHandler.keeperDay.selector;
        selectors[8] = TrailingAnchorOracleHandler.keeperDay.selector;
        selectors[9] = TrailingAnchorOracleHandler.keeperDay.selector;
        selectors[10] = TrailingAnchorOracleHandler.acceptPrice.selector;
        selectors[11] = TrailingAnchorOracleHandler.setMaxPriceIncrease.selector;
        selectors[12] = TrailingAnchorOracleHandler.setMaxPriceDecrease.selector;
        selectors[13] = TrailingAnchorOracleHandler.setAnchorLifetime.selector;
        selectors[14] = TrailingAnchorOracleHandler.setMaxAnchorRise.selector;
        selectors[15] = TrailingAnchorOracleHandler.setMaxAnchorFall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The stored values are exactly what the write rules produce from the calls made.
    function invariant_storedStateMatchesModel() public view {
        TrailingAnchorOracleState memory s = handler.shadowState();
        TrailingAnchorOracleState memory stored = TrailingAnchorOracleModel.read(oracle);
        assertEq(stored.anchorPrice, s.anchorPrice, "anchorPrice");
        assertEq(stored.anchorAt, s.anchorAt, "anchorAt");
        assertEq(stored.sourcePrice, s.sourcePrice, "sourcePrice");
        assertEq(stored.maxPriceIncrease, s.maxPriceIncrease, "maxPriceIncrease");
        assertEq(stored.maxPriceDecrease, s.maxPriceDecrease, "maxPriceDecrease");
        assertEq(stored.anchorLifetime, s.anchorLifetime, "anchorLifetime");
        assertEq(stored.maxAnchorRise, s.maxAnchorRise, "maxAnchorRise");
        assertEq(stored.maxAnchorFall, s.maxAnchorFall, "maxAnchorFall");
    }

    /// @dev The stored parameters always pass the validators.
    function invariant_parametersValid() public view {
        TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
        assertGt(s.maxPriceIncrease, 0, "increase unset");
        assertLt(s.maxPriceIncrease, WAD, "increase at a whole price");
        assertGt(s.maxPriceDecrease, 0, "decrease unset");
        assertLt(s.maxPriceDecrease, WAD, "decrease at a whole price");
        assertGt(s.anchorLifetime, 0, "lifetime unset");
        assertLt(s.anchorLifetime, TrailingAnchorOracleModel.MAX_ANCHOR_LIFETIME, "lifetime not below the cap");
        assertLe(s.maxAnchorRise, WAD, "rise speed above a whole price a year");
        assertLe(s.maxAnchorFall, WAD, "fall speed above a whole price a year");
    }

    /// @dev The anchor is never set in the future.
    function invariant_anchorNotInFuture() public view {
        assertLe(oracle.anchorAt(), block.timestamp, "anchor in the future");
    }

    /// @dev The anchor price is never zero.
    function invariant_anchorNonZero() public view {
        assertGt(oracle.anchorPrice(), 0, "zero anchor");
    }

    /// @dev Every open update left the anchor within the reach of the one before: the speeds times the time since it
    ///      moved, capped at the lifetime, so an update in the block the anchor moved cannot move it at all.
    function invariant_updateStepsWithinReach() public view {
        assertEq(handler.oversizedUpdateSteps(), 0, "an update moved the anchor too far");
    }

    /// @dev Since the last seed or acceptance, the anchor stays within the speeds compounded update by update.
    function invariant_anchorWithinReach() public view {
        uint256 anchorPrice = oracle.anchorPrice();
        assertLe(anchorPrice, handler.highestReachable(), "above the compounded rise");
        assertGe(anchorPrice, handler.lowestReachable(), "below the compounded fall");
    }

    /// @dev Since the source last took a new value, at most one open update moved the anchor, so a source that stops
    ///      changing keeps the oracle fresh for at most a lifetime after that update, however far the anchor trails it.
    function invariant_frozenSourceMovesAnchorOnce() public view {
        assertLe(handler.updatesSinceSourceChange(), 1, "a frozen source moved the anchor twice");
    }

    /// @dev An open update never changes a returned price; it can only bring one back inside the bounds.
    function invariant_updateKeepsReturnedPrice() public view {
        assertEq(handler.openCallPriceChanges(), 0, "an update changed a returned price");
    }

    /// @dev A parameter change never changes a returned price.
    function invariant_parameterChangesKeepReturnedPrice() public view {
        assertEq(handler.parameterPriceChanges(), 0, "a parameter change changed a returned price");
    }

    /// @dev A returned price sits within the bounds of the anchor, scaled.
    function invariant_priceWithinBounds() public view {
        (bool ok, bytes memory data) = address(oracle).staticcall(abi.encodeCall(TrailingAnchorOracleBase.price, ()));
        if (!ok) return;
        uint256 value = abi.decode(data, (uint256));
        TrailingAnchorOracleState memory s = handler.shadowState();
        assertGe(value, s.lowerBound() * priceScale, "price under the lower bound");
        assertLe(value, s.upperBound() * priceScale, "price over the upper bound");
    }

    /// @dev `price()` reverts with exactly the predicted error, or returns the current price times the scale.
    function invariant_priceMatchesRule() public view {
        (bool ok, bytes memory data) = address(oracle).staticcall(abi.encodeCall(TrailingAnchorOracleBase.price, ()));
        bytes memory expectedRevert = handler.predictPriceRevert();
        if (expectedRevert.length != 0) {
            assertFalse(ok, "price returned where the rule reverts");
            assertEq(data, expectedRevert, "revert data");
            return;
        }
        assertTrue(ok, "price reverted where the rule returns");
        assertEq(abi.decode(data, (uint256)), source.currentPrice() * priceScale, "price != current price x scale");
    }

    /// @dev Only the campaign's logs show that updates succeed, and an earlier handler starved them. This drives the
    ///      handler deterministically and fails if a moving update, a refusal on an unchanged source, in the block the
    ///      anchor moved or on a stale anchor, or an acceptance stops being reachable, which would leave the reach
    ///      invariants holding on nothing. The source moves through the handler, whose bound passes an in-range seed
    ///      through unchanged.
    function test_seededPaths_areNonVacuous() public {
        uint256 seeded = oracle.anchorPrice();
        // Inside the increase bound, and further than a day at the rise speed.
        uint256 target = seeded * 1.0003e18 / WAD;
        handler.stepSource(target);

        handler.keeperDay(0);
        assertEq(handler.succeeded("update"), 1, "the keeper's update succeeds");
        uint256 moved = oracle.anchorPrice();
        assertGt(moved, seeded, "the anchor rose");
        assertLt(moved, target, "a day at the rise speed falls short of the source");

        handler.keeperDay(0);
        assertEq(handler.refused("update"), 1, "an update on an unchanged source is refused");
        assertEq(oracle.anchorPrice(), moved, "the refused update kept the anchor");

        handler.stepSource(target + 1);
        handler.keeperDay(0);
        assertEq(handler.succeeded("update"), 2, "an update after the source changed succeeds");
        assertEq(oracle.anchorPrice(), target + 1, "two days at the rise speed reach the source");
        assertGt(handler.highestReachable(), target, "the compounded rise grew past the moves");

        handler.stepSource(target + 2);
        handler.updateAnchor(1);
        assertEq(handler.refused("update"), 2, "an update in the block the anchor moved is refused");

        handler.warp(TrailingAnchorOracleModel.ANCHOR_LIFETIME + 1);
        handler.stepSource(target + 3);
        handler.updateAnchor(1);
        assertEq(handler.refused("update"), 3, "an update on a stale anchor is refused");

        uint256 fallen = oracle.anchorPrice() * 0.99e18 / WAD;
        handler.moveSource(fallen);
        handler.acceptPrice(2);
        assertEq(handler.succeeded("accept"), 1, "the exact current price is accepted");
        assertEq(oracle.price(), fallen * priceScale, "the acceptance revives the stale anchor");
    }

    function afterInvariant() public {
        bytes32[7] memory actions = [
            bytes32("update"),
            "accept",
            "maxPriceIncrease",
            "maxPriceDecrease",
            "anchorLifetime",
            "maxAnchorRise",
            "maxAnchorFall"
        ];
        for (uint256 i; i < actions.length; ++i) {
            emit log_named_uint(
                string.concat(string(abi.encodePacked(actions[i])), " ok"), handler.succeeded(actions[i])
            );
            emit log_named_uint(
                string.concat(string(abi.encodePacked(actions[i])), " refused"), handler.refused(actions[i])
            );
        }
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract TrailingAnchorOracleUsdyInvariant is TrailingAnchorOracleInvariantTest, UsdyNavOracleFixture {}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract TrailingAnchorOracleCentrifugeInvariant is TrailingAnchorOracleInvariantTest, CentrifugeNavOracleFixture {}
