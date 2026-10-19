// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {UsdyOracle} from "../../src/oracle/UsdyOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {NavOracleCheckParams} from "../../src/types/NavOracleTypes.sol";

import {MockERC20, MockNavOracle, MockUsdFeed} from "../setup/Mocks.sol";
import {NavOracleModel, NavOracleState} from "../setup/NavOracleModel.sol";

import {NavOracleHandler} from "./handlers/NavOracleHandler.sol";

/// @notice Stateful invariants of one NAV oracle under any sequence of source moves, feed moves, time, open calls
///         and configurator calls. The oracle runs alone: the core only reads `price()`, so a market adds no state
///         the oracle can see.
/// @dev The handler's shadow follows the specification's write rules, so `invariant_storedStateMatchesModel` pins the
///      stored values and every other invariant recomputes from them with `NavOracleModel`.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
contract NavOracleInvariant is Test {
    using NavOracleModel for NavOracleState;

    uint256 internal constant START = 1_760_000_000;

    UsdyOracle internal oracle;
    MockNavOracle internal source;
    MockUsdFeed internal feed;
    NavOracleHandler internal handler;

    function setUp() public {
        vm.warp(START);
        // An 18-decimal loan token and a 36-decimal collateral give a `PRICE_SCALE` of one.
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 36);
        source = new MockNavOracle();
        feed = new MockUsdFeed();
        source.setPrice(1.112233445566778899e18);

        UsdyOracle impl = new UsdyOracle(address(source), address(loan), address(collateral), address(feed));
        NavOracleCheckParams memory params = NavOracleModel.workingDefaults(0.0375e18);
        bytes memory init = abi.encodeCall(NavOracleBase.initialize, (address(this), params));
        oracle = UsdyOracle(address(new OssifiableProxy(address(impl), address(this), init)));

        address configurator = makeAddr("configurator");
        oracle.grantRole(oracle.CONFIG_ROLE(), configurator);
        handler = new NavOracleHandler(oracle, source, feed, configurator);

        // Weighted: time and the open calls appear more than once, since the open calls need elapsed intervals and a
        // source near the path to succeed.
        bytes4[] memory selectors = new bytes4[](21);
        selectors[0] = NavOracleHandler.moveSource.selector;
        selectors[1] = NavOracleHandler.trackPath.selector;
        selectors[2] = NavOracleHandler.trackPath.selector;
        selectors[3] = NavOracleHandler.setSourceDown.selector;
        selectors[4] = NavOracleHandler.movePeg.selector;
        selectors[5] = NavOracleHandler.warp.selector;
        selectors[6] = NavOracleHandler.warp.selector;
        selectors[7] = NavOracleHandler.warp.selector;
        selectors[8] = NavOracleHandler.checkpoint.selector;
        selectors[9] = NavOracleHandler.checkpoint.selector;
        selectors[10] = NavOracleHandler.moveReferencePrice.selector;
        selectors[11] = NavOracleHandler.moveReferencePrice.selector;
        selectors[12] = NavOracleHandler.acceptCurrentPrice.selector;
        selectors[13] = NavOracleHandler.setGrowthLimit.selector;
        selectors[14] = NavOracleHandler.setFallLimit.selector;
        selectors[15] = NavOracleHandler.setRevertBand.selector;
        selectors[16] = NavOracleHandler.setMarketLimits.selector;
        selectors[17] = NavOracleHandler.setLoanTokenPegCheck.selector;
        selectors[18] = NavOracleHandler.releaseGrowthTolerance.selector;
        selectors[19] = NavOracleHandler.keeperDay.selector;
        selectors[20] = NavOracleHandler.keeperDay.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The stored values are exactly what the specification's write rules produce from the calls made.
    function invariant_storedStateMatchesModel() public view {
        NavOracleState memory s = handler.shadowState();
        assertEq(oracle.referencePrice(), s.referencePrice, "referencePrice");
        assertEq(oracle.referencePriceSetAt(), s.referencePriceSetAt, "referencePriceSetAt");
        assertEq(oracle.checkpointPrice(), s.checkpointPrice, "checkpointPrice");
        assertEq(oracle.checkpointAt(), s.checkpointAt, "checkpointAt");
        assertEq(oracle.protectedGrowthTolerance(), s.protectedGrowthTolerance, "protectedGrowthTolerance");
        NavOracleCheckParams memory p = oracle.checkParams();
        assertEq(keccak256(abi.encode(p)), keccak256(abi.encode(s.params)), "check parameters");
    }

    /// @dev I1.
    function invariant_floorNotAboveExpectedPrice() public view {
        NavOracleState memory s = handler.shadowState();
        assertLe(s.floor(block.timestamp), s.expectedPrice(block.timestamp), "floor above the expected price");
    }

    /// @dev I2.
    function invariant_expectedPriceNotAboveUpperBound() public view {
        NavOracleState memory s = handler.shadowState();
        assertLe(s.expectedPrice(block.timestamp), s.upperBound(block.timestamp), "expected price above the bound");
    }

    /// @dev I3.
    function invariant_openCallsKeepPrice() public view {
        assertEq(handler.openCallPriceChanges(), 0, "an open call changed the price");
    }

    /// @dev I4.
    function invariant_parameterChangesKeepPrice() public view {
        assertEq(handler.parameterPriceChanges(), 0, "a parameter change changed the price");
    }

    /// @dev I5: the corridor ratio covers the minimum grown by the interest held over one corridor crossing.
    function invariant_corridorRatioCoversProtectedTolerance() public view {
        NavOracleState memory s = handler.shadowState();
        uint256 ratio =
            NavOracleModel.corridorRatio(s.params.maxDrawdown, s.params.growthTolerance, s.protectedGrowthTolerance);
        assertGe(ratio, NavOracleModel.leastPriceRatio(s.params), "corridor ratio under the minimum");
    }

    /// @dev I6.
    function invariant_protectedToleranceCoversTolerance() public view {
        NavOracleState memory s = handler.shadowState();
        assertGe(s.protectedGrowthTolerance, s.params.growthTolerance, "protected tolerance under the tolerance");
    }

    /// @dev I7: a returned price sits between the band's lower edge and the upper bound.
    function invariant_priceWithinDrawdownAndUpperBound() public view {
        (bool ok, uint256 value) = _price();
        if (!ok) return;
        NavOracleState memory s = handler.shadowState();
        assertGe(value, s.bandLow(block.timestamp), "price under the band");
        assertLe(value, s.upperBound(block.timestamp), "price above the upper bound");
    }

    /// @dev I8: `price()` reverts with exactly the predicted error, or returns the rule over the stored state.
    function invariant_priceMatchesRule() public view {
        (bool ok, bytes memory data) = address(oracle).staticcall(abi.encodeCall(NavOracleBase.price, ()));
        bytes memory expectedRevert = handler.predictPriceRevert();
        if (expectedRevert.length != 0) {
            assertFalse(ok, "price returned where the rule reverts");
            assertEq(data, expectedRevert, "revert data");
            return;
        }
        assertTrue(ok, "price reverted where the rule returns");
        NavOracleState memory s = handler.shadowState();
        uint256 expected = s.boundedPrice(source.navPrice(), block.timestamp);
        assertEq(abi.decode(data, (uint256)), expected, "price != min(upperBound, max(source, floor))");
    }

    function afterInvariant() public {
        bytes32[9] memory actions =
            [bytes32("checkpoint"), "move", "accept", "growth", "fall", "band", "limits", "peg", "release"];
        for (uint256 i; i < actions.length; ++i) {
            emit log_named_uint(
                string.concat(string(abi.encodePacked(actions[i])), " ok"), handler.succeeded(actions[i])
            );
            emit log_named_uint(
                string.concat(string(abi.encodePacked(actions[i])), " refused"), handler.refused(actions[i])
            );
        }
    }

    function _price() internal view returns (bool, uint256) {
        (bool ok, bytes memory data) = address(oracle).staticcall(abi.encodeCall(NavOracleBase.price, ()));
        if (!ok) return (false, 0);
        return (true, abi.decode(data, (uint256)));
    }
}
