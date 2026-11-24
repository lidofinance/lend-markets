// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel, TrailingAnchorOracleState} from "../setup/TrailingAnchorOracleModel.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {
    CentrifugeNavOracleFixture,
    ChainlinkNavOracleFixture,
    NavOracleFixture,
    UsdyNavOracleFixture
} from "../setup/NavOracleFixtures.sol";

import {TrailingAnchorOracleHandler} from "./handlers/TrailingAnchorOracleHandler.sol";

/// @notice Stateful invariants of one anchor oracle under any sequence of source moves, time, open updates, price
///         acceptances, parameter changes and suspensions, run once through each adapter. The oracle runs alone: the
///         core only reads `price()`, so a market adds no state the oracle can see.
/// @dev The handler's shadow follows the model, so `invariant_storedStateMatchesModel` pins the stored values; the
///      move, floor, ceiling, pending anchor and suspension invariants check the bounds, rate, floor and ceiling
///      formulas directly.
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
        oracle = TrailingAnchorOracleBase(
            address(
                new OssifiableProxy(
                    _newImplementation(address(loan)),
                    address(this),
                    TrailingAnchorOracleModel.initializeCall(address(this))
                )
            )
        );

        address manager = makeAddr("manager");
        address priceAcceptor = makeAddr("priceAcceptor");
        oracle.grantRole(oracle.MANAGER_ROLE(), manager);
        oracle.grantRole(oracle.PRICE_ACCEPTOR_ROLE(), priceAcceptor);
        handler = new TrailingAnchorOracleHandler(oracle, source, manager, priceAcceptor, _maxPriceAge(), _lltv());

        // Weighted: source moves, window edges, updates, the keeper's hour and a source settling at its pending anchor
        // appear more than once, since a pending anchor needs a price outside the bounds and a re-anchor needs its
        // window. A stamped source also restamps its price.
        bytes4[] memory selectors = new bytes4[](_maxPriceAge() == 0 ? 19 : 20);
        selectors[0] = TrailingAnchorOracleHandler.stepSource.selector;
        selectors[1] = TrailingAnchorOracleHandler.stepSource.selector;
        selectors[2] = TrailingAnchorOracleHandler.moveSource.selector;
        selectors[3] = TrailingAnchorOracleHandler.jumpSource.selector;
        selectors[4] = TrailingAnchorOracleHandler.setSourceDown.selector;
        selectors[5] = TrailingAnchorOracleHandler.warp.selector;
        selectors[6] = TrailingAnchorOracleHandler.warpToWindowEdge.selector;
        selectors[7] = TrailingAnchorOracleHandler.warpToWindowEdge.selector;
        selectors[8] = TrailingAnchorOracleHandler.updateAnchor.selector;
        selectors[9] = TrailingAnchorOracleHandler.updateAnchor.selector;
        selectors[10] = TrailingAnchorOracleHandler.updateAnchor.selector;
        selectors[11] = TrailingAnchorOracleHandler.keeperTick.selector;
        selectors[12] = TrailingAnchorOracleHandler.keeperTick.selector;
        selectors[13] = TrailingAnchorOracleHandler.acceptPrice.selector;
        selectors[14] = TrailingAnchorOracleHandler.setParameters.selector;
        selectors[15] = TrailingAnchorOracleHandler.setPricingResumesAt.selector;
        selectors[16] = TrailingAnchorOracleHandler.moveSource.selector;
        selectors[17] = TrailingAnchorOracleHandler.settleAtPendingAnchor.selector;
        selectors[18] = TrailingAnchorOracleHandler.settleAtPendingAnchor.selector;
        if (_maxPriceAge() != 0) selectors[19] = TrailingAnchorOracleHandler.setPriceStamp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The LLTV the handler keeps the parameters sized for: none in the shared suites, so they can move the floor
    ///      and the ceiling out of the way.
    function _lltv() internal pure virtual returns (uint256) {
        return 0;
    }

    /// @dev The adapter's `MAX_PRICE_AGE` when its source stamps the price: none in the shared suites.
    function _maxPriceAge() internal pure virtual returns (uint256) {
        return 0;
    }

    /// @dev The stored values are exactly what the model produces from the calls made.
    function invariant_storedStateMatchesModel() public view {
        assertEq(abi.encode(TrailingAnchorOracleModel.read(oracle)), abi.encode(handler.shadowState()), "state");
    }

    /// @dev The stored parameters always pass the validator.
    function invariant_parametersValid() public view {
        TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleBase.Parameters({
            maxPriceAboveAnchor: uint64(s.maxPriceAboveAnchor),
            maxPriceBelowAnchor: uint64(s.maxPriceBelowAnchor),
            maxAnchorContinuousRiseRate: uint64(s.maxAnchorContinuousRiseRate),
            maxAnchorContinuousFallRate: uint64(s.maxAnchorContinuousFallRate),
            maxAnchorBelowBase: uint64(s.maxAnchorBelowBase),
            maxAnchorAboveBase: uint64(s.maxAnchorAboveBase),
            reanchorDelay: uint40(s.reanchorDelay),
            reanchorWindow: uint40(s.reanchorWindow)
        });
        assertEq(TrailingAnchorOracleModel.parametersRevert(p).length, 0, "stored parameters out of range");
    }

    /// @dev The anchor is never zero nor set in the future.
    function invariant_anchorNonZeroAndNotInFuture() public view {
        assertGt(oracle.anchorPrice(), 0, "zero anchor");
        assertLe(oracle.anchorAt(), block.timestamp, "anchor in the future");
    }

    /// @dev A pending anchor's price and time are set together, never in the future, and the price sits outside the
    ///      anchor's bounds: the anchor never moves, nor do the bounds change, while a pending anchor stands.
    function invariant_pendingAnchorConsistent() public view {
        TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
        assertEq(s.pendingAnchorPrice == 0, s.pendingAnchorAt == 0, "price and time set apart");
        if (s.pendingAnchorAt == 0) return;
        assertLe(s.pendingAnchorAt, block.timestamp, "pending anchor in the future");
        assertFalse(s.withinBounds(s.pendingAnchorPrice), "pending anchor within the anchor's bounds");
    }

    /// @dev `price()` reverts with exactly the predicted error, or returns the current price times the scale, which
    ///      then sits within the anchor's bounds.
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
        TrailingAnchorOracleState memory s = handler.shadowState();
        assertTrue(s.withinBounds(source.currentPrice()), "a returned price outside the anchor's bounds");
    }

    /// @dev An update never stops or changes a price `price()` returned just before it.
    function invariant_updateKeepsReturnedPrice() public view {
        assertEq(handler.stoppedPrices(), 0, "an update stopped a returned price");
    }

    /// @dev Every anchor move by an update is a drift toward a price within the bounds, inside the rates' reach, or a
    ///      move onto the nearer of the price and a pending anchor recorded at least the delay before, with the price
    ///      outside the bounds on the pending anchor's side, and onto the floor or the ceiling when that is nearer
    ///      still.
    function invariant_anchorMovesOnlyByReachOrWaitedSteps() public view {
        assertEq(handler.strayAnchorMoves(), 0, "an anchor move outside the rules");
    }

    /// @dev No update sets the anchor under the floor, `maxAnchorBelowBase` below the base price, unless the
    ///      anchor already sat under it.
    function invariant_anchorNeverUnderTheFloor() public view {
        assertEq(handler.floorBreaches(), 0, "an update moved the anchor under the floor");
    }

    /// @dev No update leaves the anchor further over the base price than both `maxAnchorAboveBase` of it and
    ///      its distance before the update: a re-anchor up stops on the ceiling, and a drift keeps the gap.
    function invariant_anchorNeverOverTheCeiling() public view {
        assertEq(handler.ceilingBreaches(), 0, "an update moved the anchor over the ceiling");
    }

    /// @dev The stored base price follows its rule: the seed or the last acceptance, raised by each drift up and
    ///      left by re-anchors. The anchor sits over it by at most `maxAnchorAboveBase` of it, or by its gap at
    ///      the last parameter change when a narrower `maxAnchorAboveBase` left it higher.
    function invariant_basePriceFollowsItsRule() public view {
        uint256 basePrice = oracle.basePrice();
        assertEq(basePrice, handler.expectedBasePrice(), "basePrice");
        uint256 anchor = oracle.anchorPrice();
        uint256 gap = anchor > basePrice ? anchor - basePrice : 0;
        uint256 allowed =
            Math.max(Math.mulDiv(basePrice, oracle.maxAnchorAboveBase(), WAD), handler.gapAtParameterChange());
        assertLe(gap, allowed, "an anchor too far over the base price");
    }

    /// @dev A parameter change never changes a returned price.
    function invariant_parameterChangesKeepReturnedPrice() public view {
        assertEq(handler.parameterPriceChanges(), 0, "a parameter change changed a returned price");
    }

    /// @dev A suspension never ends more than `MAX_PRICING_SUSPENSION` after the call that set it.
    function invariant_suspensionWithinCap() public view {
        assertLe(
            oracle.pricingResumesAt(),
            handler.suspensionSetAt() + TrailingAnchorOracleModel.MAX_PRICING_SUSPENSION,
            "suspension past its cap"
        );
    }

    /// @dev Only the campaign's logs show that each path is reached. This drives the handler deterministically and
    ///      fails if a drift, a pending anchor, a held update, an expiry, a re-anchor, a re-anchor onto the floor or
    ///      the ceiling, a pinned update or an acceptance stops being reachable, which would leave the invariants
    ///      holding on nothing.
    function test_seededPaths_areNonVacuous() public {
        uint256 anchor = oracle.anchorPrice();
        handler.stepSource(anchor * 1.0003e18 / WAD);
        handler.keeperTick(0);
        assertEq(handler.succeeded("drift"), 1, "a drift");

        handler.jumpSource(uint256(oracle.anchorPrice()) * 0.995e18 / WAD);
        handler.updateAnchor(1);
        assertEq(handler.succeeded("pendingAnchor"), 1, "a pending anchor");
        handler.updateAnchor(2);
        assertEq(handler.succeeded("pendingAnchor"), 1, "a held update records nothing");

        vm.warp(handler.shadowState().closesAt() + 1);
        handler.updateAnchor(3);
        assertEq(handler.succeeded("pendingAnchor"), 2, "an expired pending anchor recorded anew");
        assertEq(oracle.pendingAnchorAt(), block.timestamp, "at the update's time");

        handler.warpToWindowEdge(_seedFor(1));
        handler.updateAnchor(4);
        assertEq(handler.succeeded("reanchor"), 1, "a re-anchor when the window opens");
        assertEq(oracle.pendingAnchorAt(), 0, "the price sits within the new bounds");

        // A 10% fall stops on the floor, and the next window finds the anchor pinned there.
        handler.jumpSource(uint256(oracle.anchorPrice()) * 0.9e18 / WAD);
        handler.updateAnchor(6);
        handler.warpToWindowEdge(_seedFor(1));
        handler.updateAnchor(7);
        assertEq(handler.succeeded("floor"), 1, "a re-anchor onto the floor");
        handler.warpToWindowEdge(_seedFor(1));
        handler.updateAnchor(8);
        assertEq(handler.succeeded("pinned"), 1, "a pinned update");

        // A 5% rise from the floor stops on the ceiling, and the next window finds the anchor pinned there.
        handler.jumpSource(uint256(oracle.anchorPrice()) * 1.05e18 / WAD);
        handler.updateAnchor(5);
        handler.warpToWindowEdge(_seedFor(1));
        handler.updateAnchor(9);
        assertEq(handler.succeeded("ceiling"), 1, "a re-anchor onto the ceiling");
        handler.warpToWindowEdge(_seedFor(1));
        handler.updateAnchor(10);
        assertEq(handler.succeeded("pinned"), 2, "a pinned update on the ceiling");
        assertGt(oracle.pendingAnchorAt(), 0, "a pending anchor to drop");
        handler.acceptPrice(2);
        assertEq(handler.succeeded("accept"), 1, "the exact current price is accepted");
        assertEq(oracle.pendingAnchorAt(), 0, "the acceptance drops the pending anchor");

        handler.setParameters(_parametersSeed(true));
        assertEq(handler.succeeded("parameters"), 1, "a parameter set the validator takes");
        handler.setParameters(_parametersSeed(false));
        assertEq(handler.refused("parameters"), 1, "a parameter set the validator refuses");
    }

    /// @dev A seed whose parameters the validator takes, or refuses, and which pass the sizing rule at the suite's
    ///      LLTV, so the handler sends them.
    function _parametersSeed(bool taken) internal view returns (uint256 seed) {
        while (
            (TrailingAnchorOracleModel.parametersRevert(handler.parametersFor(seed)).length == 0) != taken
                || (_lltv() != 0 && !TrailingAnchorOracleModel.sized(handler.parametersFor(seed), _lltv()))
        ) ++seed;
    }

    /// @dev A seed whose edge pick is `index`: 0 the delay's last second, 1 the window's first second.
    function _seedFor(uint256 index) internal pure returns (uint256 seed) {
        while (uint256(keccak256(abi.encode(seed, "edge"))) % 4 != index) ++seed;
    }

    function afterInvariant() public {
        bytes32[13] memory actions = [
            bytes32("update"),
            "drift",
            "pendingAnchor",
            "reanchor",
            "floor",
            "ceiling",
            "pinned",
            "accept",
            "parameters",
            "suspension",
            "stale",
            "future",
            "expiredWhileStale"
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

/// @notice The campaign over a source that stamps its price, with the stamp action.
abstract contract TrailingAnchorOracleStampedInvariantTest is TrailingAnchorOracleInvariantTest {
    /// @dev The stamp action reaches each refusal of the source's stamp: a pending anchor whose window closes while the
    ///      price is stale, and a price stamped after the block. A fresh stamp then records a new pending anchor.
    function test_stampCases_areReachable() public {
        handler.moveSource(0);
        handler.updateAnchor(0);
        assertEq(handler.succeeded("pendingAnchor"), 1, "a pending anchor");
        handler.setPriceStamp(_stampSeed(0));
        uint256 closesAt = handler.shadowState().pendingAnchorAt + handler.shadowState().reanchorDelay
            + handler.shadowState().reanchorWindow;
        while (block.timestamp <= closesAt) handler.warp(3 days);
        handler.updateAnchor(0);
        assertEq(handler.refused("expiredWhileStale"), 1, "a window that closed while the price was stale");
        handler.setPriceStamp(_stampSeed(1));
        handler.updateAnchor(0);
        assertEq(handler.refused("future"), 1, "a price stamped after the block");
        handler.setPriceStamp(_stampSeed(4));
        handler.updateAnchor(0);
        assertEq(handler.succeeded("pendingAnchor"), 2, "a new pending anchor in place of the expired one");
    }

    /// @dev A seed whose stamp pick is `kind`: 0 stale, 1 after the block, 4 fresh.
    function _stampSeed(uint256 kind) internal pure returns (uint256 seed) {
        while (uint256(keccak256(abi.encode(seed, "stamp"))) % 8 != kind) ++seed;
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract TrailingAnchorOracleCentrifugeInvariant is
    TrailingAnchorOracleStampedInvariantTest,
    CentrifugeNavOracleFixture
{
    function _maxPriceAge() internal pure override returns (uint256) {
        return MAX_PRICE_AGE;
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract TrailingAnchorOracleChainlinkInvariant is TrailingAnchorOracleStampedInvariantTest, ChainlinkNavOracleFixture {
    function _maxPriceAge() internal pure override returns (uint256) {
        return MAX_PRICE_AGE;
    }
}

/// @notice The same campaign with a manager that keeps the parameters inside the sizing rule at a 98% LLTV, so that
///         the returned prices are checked against it.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract TrailingAnchorOracleSizedInvariant is TrailingAnchorOracleInvariantTest, UsdyNavOracleFixture {
    function _lltv() internal pure override returns (uint256) {
        return 0.98e18;
    }

    /// @dev What the sizing rule is for: while the anchor started between the floor and the ceiling, every price
    ///      `price()` returns covers a debt borrowed at the LLTV against the highest price returned since the last
    ///      acceptance or parameter change, with the core's liquidation incentive on top.
    function invariant_returnedPriceCoversDebtAtTheHighest() public view {
        assertEq(handler.uncoveredPrices(), 0, "a returned price under LLTV x LIF of an earlier one");
    }

    /// @dev A returned price is checked against the highest one. And the handler holds back a set that the oracle
    ///      would take and the sizing rule refuses.
    function test_seededSizing_isNonVacuous() public {
        handler.stepSource(0);
        assertEq(handler.checkedPrices(), 1, "a returned price checked against the highest");
        uint256 seed;
        while (
            TrailingAnchorOracleModel.parametersRevert(handler.parametersFor(seed)).length != 0
                || TrailingAnchorOracleModel.sized(handler.parametersFor(seed), _lltv())
        ) ++seed;
        handler.setParameters(seed);
        assertEq(handler.succeeded("parameters") + handler.refused("parameters"), 0, "an unsized set is not sent");
    }
}
