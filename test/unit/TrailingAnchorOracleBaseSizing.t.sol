// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {MockERC20} from "../setup/Mocks.sol";
import {MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";
import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";

/// @notice The rules `setParameters()` checks against `MAX_LLTV` and the delay. The expected edges come from the
///         spec's sizing formula, written out here, not from the oracle.
contract TrailingAnchorOracleBaseSizingTest is Test {
    uint256 internal constant WAD = 1e18;
    /// @dev The oracle rounds the needed side up and the room side down, so it may refuse a line up to this many wei
    ///      inside the edge of the rule. In wei of a whole price, the two ceilings on the needed side add less than
    ///      (1 + above)(1 + ceiling) + (1 + ceiling). The floor on the room and the last ceiling add less than 1
    ///      together, since an integer is below ceil(y) only if it is below y. A ceiling k wei inside the edge leaves
    ///      k × LLTV × LIF × (1 + above) of room, so a refusal needs that sum to be more. The edge stays under a
    /// whole
    ///      price, so LLTV × LIF × (1 + above) is at least half the room, and k is at most 10. The floor needs only
    /// 3.
    uint256 internal constant MAX_ROUNDING_GAP = 10;

    MockOndoPriceGetter internal getter;
    MockERC20 internal usdc;
    MockERC20 internal usdy;
    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");

    function setUp() public {
        vm.warp(1_760_000_000);
        getter = new MockOndoPriceGetter();
        getter.setCurrentPrice(1e18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdy = new MockERC20("Ondo US Dollar Yield", "USDY", 18);
    }

    function testRevert_constructor_maxLltvNotBelowWad() public {
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxLltv.selector, WAD));
        new UsdyNavOracle(address(getter), address(usdc), address(usdy), WAD);
        UsdyNavOracle impl = new UsdyNavOracle(address(getter), address(usdc), address(usdy), WAD - 1);
        assertEq(impl.MAX_LLTV(), WAD - 1, "MAX_LLTV");
    }

    /// @dev The largest `maxAnchorAboveFenceBase` the sizing rule leaves over each class's floor, as the spec gives it:
    ///      0.26% at a 98% LLTV with bounds of +0.05% and −0.1% and a 1% floor, 0.31% at ±0.05%, 0.21% at ±0.1%,
    ///      and 1.23% at 92% with ±0.3% and 4%. Each edge passes, and one wei more is refused.
    function test_setParameters_largestAboveFenceBaseIsTheEdge() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        _assertAboveFenceBaseEdge(p, 0.98e18, 0.0026e18, "0.26% at 98%");
        p.maxPriceBelowAnchor = 0.0005e18;
        _assertAboveFenceBaseEdge(p, 0.98e18, 0.0031e18, "0.31% at 98% with 0.05% bounds");
        p.maxPriceAboveAnchor = 0.001e18;
        p.maxPriceBelowAnchor = 0.001e18;
        _assertAboveFenceBaseEdge(p, 0.98e18, 0.0021e18, "0.21% at 98% with 0.1% bounds");
        p.maxPriceAboveAnchor = 0.003e18;
        p.maxPriceBelowAnchor = 0.003e18;
        p.maxAnchorBelowFenceBase = 0.04e18;
        _assertAboveFenceBaseEdge(p, 0.92e18, 0.0123e18, "1.23% at 92% with 0.3% bounds and 4%");
    }

    /// @dev Under an LLTV of about 56.5% the core holds the liquidation incentive at 1.15. At 50% the rule needs
    ///      0.5 × 1.15 × 1.0005 = 0.5752875 of the 0.99 × 0.999 the floor leaves, so the ceiling may sit 71.92% over
    ///      the fence base price. With the incentive not held, 1 / 0.85, it would stop at 68.05%.
    function test_setParameters_edgeWhereTheIncentiveIsHeld() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        _assertAboveFenceBaseEdge(p, 0.5e18, 0.71916e18, "71.92% at 50%");
    }

    /// @dev The other way round: with the working 0.2% ceiling the rule allows a floor about 1.06% under the fence base
    ///      price at 98%, and with a 1% ceiling at 92% and ±0.3% bounds about 4.22%. Each edge passes, and one wei
    ///      deeper is refused.
    function test_setParameters_largestBelowFenceBaseIsTheEdge() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        uint256 largest = _largestBelowFenceBase(p, 0.98e18);
        assertApproxEqAbs(largest, 0.0106e18, 0.00005e18, "1.06% at 98%");
        TrailingAnchorOracleBase oracle = _deploy(0.98e18);
        p.maxAnchorBelowFenceBase = uint64(largest);
        _set(oracle, p);
        p.maxAnchorBelowFenceBase = uint64(largest + 1);
        _expectRefused(oracle, p);

        p.maxPriceAboveAnchor = 0.003e18;
        p.maxPriceBelowAnchor = 0.003e18;
        p.maxAnchorAboveFenceBase = 0.01e18;
        largest = _largestBelowFenceBase(p, 0.92e18);
        assertApproxEqAbs(largest, 0.0422e18, 0.00005e18, "4.22% at 92% with 0.3% bounds and 1%");
        oracle = _deploy(0.92e18);
        p.maxAnchorBelowFenceBase = uint64(largest);
        _set(oracle, p);
        p.maxAnchorBelowFenceBase = uint64(largest + 1);
        _expectRefused(oracle, p);
    }

    /// @dev The working 1% floor and 0.2% ceiling fit a 98% LLTV and not 98.2%, where the rule allows a ceiling of
    ///      only about 0.12%: `initialize` refuses them there as `setParameters` does.
    function testRevert_initialize_corridorTooWideForTheMaxLltv() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        assertApproxEqAbs(_largestAboveFenceBase(p, 0.982e18), 0.0012e18, 0.00005e18, "about 0.12% at 98.2%");
        address impl = address(new UsdyNavOracle(address(getter), address(usdc), address(usdy), 0.982e18));
        bytes memory init = TrailingAnchorOracleModel.initializeCall(admin, p);
        vm.expectRevert(TrailingAnchorOracleBase.InvalidParameters.selector);
        new OssifiableProxy(impl, admin, init);
    }

    /// @dev The fall side of the delay rule: with a 0.1% lower bound and a 48-hour delay a source may fall at most
    ///      0.1% × 365 days / 48 hours = 18.25% a year and stay within the bound over one delay. The edge passes, and
    ///      one wei more is refused. The rise speed is off so that its own delay rule does not bind first.
    function test_setParameters_fallSpeedEdgeOverOneDelay() public {
        TrailingAnchorOracleBase oracle = _deploy(0.98e18);
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorRisePerYear = 0;
        p.reanchorDelay = 48 hours;
        p.maxAnchorFallPerYear = 0.1825e18;
        _set(oracle, p);
        p.maxAnchorFallPerYear = 0.1825e18 + 1;
        _expectRefused(oracle, p);
    }

    /// @dev Any LLTV and any corridor: `setParameters()` takes the parameters only if the lowest price the oracle can
    ///      return covers a debt borrowed at `MAX_LLTV` against the highest, with the core's incentive on top, and
    ///      refuses them only if it does not. The inequality is checked in whole numbers with no division, so it shares
    ///      no rounding with the oracle; the two may differ by the few wei the oracle rounds against the corridor.
    ///      The oracle's rounding refuses a set up to 4.1 wei over the rule and takes one up to 3.7 wei under it.
    function testFuzz_setParameters_takesACorridorOnlyIfItCoversTheLiquidation(
        uint256 maxLltv,
        uint64 above,
        uint64 below,
        uint64 belowFenceBase,
        uint64 aboveFenceBase
    ) public {
        maxLltv = bound(maxLltv, 0.3e18, 0.99e18);
        TrailingAnchorOracleBase.Parameters memory p = _narrowest();
        TrailingAnchorOracleBase oracle = _deploy(maxLltv, p);
        p.maxPriceAboveAnchor = uint64(bound(above, 1, 0.05e18));
        p.maxPriceBelowAnchor = uint64(bound(below, 1, 0.05e18));
        p.maxAnchorBelowFenceBase = uint64(bound(belowFenceBase, 0, 0.5e18));
        p.maxAnchorAboveFenceBase = uint64(bound(aboveFenceBase, 0, 0.5e18));

        vm.prank(manager);
        try oracle.setParameters(p) {
            assertTrue(_covers(p, maxLltv, 0, 4), "taken, so the corridor covers the liquidation");
        } catch (bytes memory revertData) {
            assertEq(bytes4(revertData), TrailingAnchorOracleBase.InvalidParameters.selector, "refused by the rule");
            assertFalse(_covers(p, maxLltv, 5, 0), "refused, so the corridor does not cover the liquidation");
        }
    }

    /// @dev At the edge of the sizing rule: the fuzzer picks `MAX_LLTV`, the bounds and one line, and the other line
    ///      sits near the widest value the spec's rule allows for them. The oracle refuses every set the rule
    ///      refuses, and refuses a set the rule takes only within `MAX_ROUNDING_GAP` of the edge.
    function testFuzz_setParameters_edgeOfTheSizingRule(
        uint256 maxLltv,
        uint64 above,
        uint64 below,
        uint64 otherLine,
        bool solveCeiling,
        int256 offset
    ) public {
        maxLltv = bound(maxLltv, 0.3e18, 0.99e18);
        TrailingAnchorOracleBase.Parameters memory p = _narrowest();
        TrailingAnchorOracleBase oracle = _deploy(maxLltv, p);
        p.maxPriceAboveAnchor = uint64(bound(above, 1, 0.01e18));
        p.maxPriceBelowAnchor = uint64(bound(below, 1, 0.01e18));
        _setLine(p, !solveCeiling, bound(otherLine, 0, 0.05e18));
        uint256 edge = _widestLine(p, maxLltv, solveCeiling);
        vm.assume(edge >= 2 * MAX_ROUNDING_GAP && edge <= WAD - 10);
        offset = bound(offset, -2 * int256(MAX_ROUNDING_GAP), int256(MAX_ROUNDING_GAP));
        _setLine(p, solveCeiling, uint256(int256(edge) + offset));
        bool holds = TrailingAnchorOracleModel.sized(p, maxLltv);
        assertEq(holds, offset <= 0, "the rule holds up to the edge");

        vm.prank(manager);
        try oracle.setParameters(p) {
            assertTrue(holds, "taken where the rule fails");
        } catch (bytes memory revertData) {
            assertEq(bytes4(revertData), TrailingAnchorOracleBase.InvalidParameters.selector, "refused by the rule");
            if (holds) {
                assertLe(uint256(-offset), MAX_ROUNDING_GAP, "refused further inside the edge than the rounding");
            }
        }
    }

    /// @dev A ceiling 9 wei inside the edge of the rule at a 43.16% LLTV: the rule takes it, and the oracle's rounding
    ///      refuses it.
    function test_setParameters_ceilingNineWeiInsideTheEdgeIsWithinTheRounding() public {
        testFuzz_setParameters_edgeOfTheSizingRule(
            431558710300315627, 1881934947331682, 7062787411673335, 24141113695334605, true, -9
        );
    }

    /// @dev `MAX_LLTV` belongs to the implementation, so an upgrade can raise it, and it leaves the stored parameters
    ///      as they are: a corridor sized for 92% stays on an oracle that now reads 98%, until the next
    ///      `setParameters()` call, which refuses the same values.
    function test_upgrade_higherMaxLltvKeepsParametersItWouldRefuse() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxPriceAboveAnchor = 0.003e18;
        p.maxPriceBelowAnchor = 0.003e18;
        p.maxAnchorBelowFenceBase = 0.04e18;
        p.maxAnchorAboveFenceBase = 0.01e18;
        TrailingAnchorOracleBase oracle = _deploy(0.92e18, p);

        address sizedFor98 = address(new UsdyNavOracle(address(getter), address(usdc), address(usdy), 0.98e18));
        vm.prank(admin);
        OssifiableProxy(payable(address(oracle))).proxy__upgradeTo(sizedFor98);

        assertEq(oracle.MAX_LLTV(), 0.98e18, "MAX_LLTV after the upgrade");
        assertEq(oracle.maxAnchorBelowFenceBase(), 0.04e18, "the 4% floor stays");
        assertEq(oracle.maxAnchorAboveFenceBase(), 0.01e18, "the 1% ceiling stays");
        _expectRefused(oracle, p);
    }

    // ---
    // HELPERS
    // ---

    function _deploy(uint256 maxLltv) internal returns (TrailingAnchorOracleBase) {
        return _deploy(maxLltv, TrailingAnchorOracleModel.defaultParameters());
    }

    function _deploy(uint256 maxLltv, TrailingAnchorOracleBase.Parameters memory p)
        internal
        returns (TrailingAnchorOracleBase oracle)
    {
        address impl = address(new UsdyNavOracle(address(getter), address(usdc), address(usdy), maxLltv));
        oracle = TrailingAnchorOracleBase(
            address(new OssifiableProxy(impl, admin, TrailingAnchorOracleModel.initializeCall(admin, p)))
        );
        bytes32 managerRole = oracle.MANAGER_ROLE();
        vm.prank(admin);
        oracle.grantRole(managerRole, manager);
    }

    function _set(TrailingAnchorOracleBase oracle, TrailingAnchorOracleBase.Parameters memory p) internal {
        vm.prank(manager);
        oracle.setParameters(p);
    }

    function _expectRefused(TrailingAnchorOracleBase oracle, TrailingAnchorOracleBase.Parameters memory p) internal {
        vm.prank(manager);
        vm.expectRevert(TrailingAnchorOracleBase.InvalidParameters.selector);
        oracle.setParameters(p);
    }

    /// @dev Checks that `p`'s largest `maxAnchorAboveFenceBase` at `lltv` is about `expected`, that an oracle sized for
    ///      `lltv` takes it, and that it refuses one wei more.
    function _assertAboveFenceBaseEdge(
        TrailingAnchorOracleBase.Parameters memory p,
        uint256 lltv,
        uint256 expected,
        string memory label
    ) internal {
        uint256 largest = _largestAboveFenceBase(p, lltv);
        assertApproxEqAbs(largest, expected, 0.00005e18, label);
        TrailingAnchorOracleBase oracle = _deploy(lltv);
        p.maxAnchorAboveFenceBase = uint64(largest);
        _set(oracle, p);
        p.maxAnchorAboveFenceBase = uint64(largest + 1);
        _expectRefused(oracle, p);
    }

    /// @dev The widest `maxAnchorAboveFenceBase` the sizing rule allows, from the spec's formula: the highest price the
    ///      oracle returns, the ceiling × (1 + maxPriceAboveAnchor), times LLTV × LIF must stay under the lowest, the
    ///      floor × (1 − maxPriceBelowAnchor), with LIF = min(1.15, 1 / (1 − 0.3 × (1 − LLTV))) rounded down as
    /// the
    ///      core rounds it, and every other step rounded against the corridor.
    function _largestAboveFenceBase(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 room = (WAD - p.maxAnchorBelowFenceBase) * (WAD - p.maxPriceBelowAnchor) / WAD;
        uint256 needed = _neededAtTheFenceBase(p, lltv);
        return room < needed ? 0 : room * WAD / needed - WAD;
    }

    /// @dev The widest `maxAnchorBelowFenceBase` the sizing rule allows for `p`'s `maxAnchorAboveFenceBase`, from the
    ///      same formula.
    function _largestBelowFenceBase(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 needed = _ceilDiv(_neededAtTheFenceBase(p, lltv) * (WAD + p.maxAnchorAboveFenceBase), WAD);
        return WAD - _ceilDiv(needed * WAD, WAD - p.maxPriceBelowAnchor);
    }

    /// @dev What the rule needs with the ceiling on the fence base price: LLTV × LIF × (1 + maxPriceAboveAnchor),
    ///      with LIF rounded down as the core rounds it, and each other step rounded up.
    function _neededAtTheFenceBase(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 lif = WAD * WAD / (WAD - 0.3e18 * (WAD - lltv) / WAD);
        if (lif > 1.15e18) lif = 1.15e18;
        return _ceilDiv(_ceilDiv(lltv * lif, WAD) * (WAD + p.maxPriceAboveAnchor), WAD);
    }

    /// @dev Parameters every LLTV up to 99% takes: 0.01% bounds, the floor and the ceiling on the fence base price,
    ///      both speeds off and the shortest delay, so that only the sizing rule decides the fuzzed corridor.
    function _narrowest() internal pure returns (TrailingAnchorOracleBase.Parameters memory p) {
        p.maxPriceAboveAnchor = 0.0001e18;
        p.maxPriceBelowAnchor = 0.0001e18;
        p.reanchorDelay = 1 hours;
        p.reanchorWindow = 1;
    }

    /// @dev The sizing rule in whole numbers: (1 − below fence)(1 − below anchor) ≥ LLTV × LIF × (1 + above
    ///      fence)(1 + above anchor), with LIF = 10 / (7 + 3 × LLTV), or 1.15 where that is higher, and both sides
    ///      multiplied through. `slackFor` wei of a whole price are added to the left side and `slackAgainst` taken
    ///      from it.
    function _covers(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv, uint256 slackAgainst, uint256 slackFor)
        internal
        pure
        returns (bool)
    {
        uint256 room = (WAD - p.maxAnchorBelowFenceBase) * (WAD - p.maxPriceBelowAnchor);
        uint256 reach = (WAD + p.maxAnchorAboveFenceBase) * (WAD + p.maxPriceAboveAnchor);
        room = room + slackFor * WAD - slackAgainst * WAD;
        if (10 * WAD * 100 > 115 * (7 * WAD + 3 * lltv)) return room * 100 * WAD >= 115 * lltv * reach;
        return room * (7 * WAD + 3 * lltv) >= 10 * lltv * reach;
    }

    /// @dev The widest value of the ceiling, or of the floor, under a whole price for which the spec's rule holds with
    ///      the rest of `p`, by bisection on the model. Zero when the rule fails even with that line at zero.
    function _widestLine(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv, bool ceiling)
        internal
        pure
        returns (uint256 widest)
    {
        uint256 refused = WAD;
        while (refused - widest > 1) {
            uint256 middle = (widest + refused) / 2;
            _setLine(p, ceiling, middle);
            if (TrailingAnchorOracleModel.sized(p, lltv)) widest = middle;
            else refused = middle;
        }
    }

    function _setLine(TrailingAnchorOracleBase.Parameters memory p, bool ceiling, uint256 value) internal pure {
        if (ceiling) p.maxAnchorAboveFenceBase = uint64(value);
        else p.maxAnchorBelowFenceBase = uint64(value);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
