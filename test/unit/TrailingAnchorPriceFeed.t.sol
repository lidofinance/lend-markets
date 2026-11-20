// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {TrailingAnchorKind, TrailingAnchorPriceFeedSpec} from "../../script/deployment/DeploymentTypes.sol";
import {TrailingAnchorPriceFeed} from "../../script/deployment/TrailingAnchorPriceFeed.sol";

import {MockERC20} from "../setup/Mocks.sol";
import {MockCentrifugeSpoke, MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";
import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";

/// @dev External entry points, so that a test can expect a revert of the library.
contract TrailingAnchorPriceFeedHarness {
    function implementation(TrailingAnchorPriceFeedSpec memory spec) external returns (address) {
        return TrailingAnchorPriceFeed.implementation(spec);
    }

    function checkLaunch(address oracle, TrailingAnchorPriceFeedSpec memory spec, address agent) external view {
        TrailingAnchorPriceFeed.checkLaunch(oracle, spec, agent);
    }

    function checkLive(address oracle, uint256 lltv) external view {
        TrailingAnchorPriceFeed.checkLive(oracle, lltv);
    }

    function requireSizing(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv) external pure {
        TrailingAnchorPriceFeed.requireSizing(p, lltv);
    }
}

/// @notice The checks on a deployed oracle: the launch parameters, each role held by the Agent alone, the sizing rule
///         at the market's LLTV and the anchor between the floor and the ceiling.
contract TrailingAnchorPriceFeedTest is Test {
    uint256 internal constant LLTV = 0.98e18;

    TrailingAnchorPriceFeedHarness internal harness;
    MockOndoPriceGetter internal getter;
    address internal agent = makeAddr("agent");
    address internal other = makeAddr("other");
    TrailingAnchorPriceFeedSpec internal spec;
    TrailingAnchorOracleBase internal nav;

    function setUp() external {
        vm.warp(1_760_000_000);
        harness = new TrailingAnchorPriceFeedHarness();
        getter = new MockOndoPriceGetter();
        getter.setCurrentPrice(1e18);
        spec.kind = TrailingAnchorKind.Usdy;
        spec.source = address(getter);
        spec.loanToken = address(new MockERC20("USD Coin", "USDC", 6));
        spec.collateralToken = address(new MockERC20("Ondo US Dollar Yield", "USDY", 18));
        spec.parameters = TrailingAnchorOracleModel.defaultParameters();
        spec.seedMinPrice = 0.99e18;
        spec.seedMaxPrice = 1.01e18;
        nav = _launch();
    }

    function test_kindName_namesEachKind() external pure {
        assertEq(TrailingAnchorPriceFeed.kindName(TrailingAnchorKind.Usdy), "usdy-nav", "Usdy");
        assertEq(TrailingAnchorPriceFeed.kindName(TrailingAnchorKind.Centrifuge), "centrifuge-nav", "Centrifuge");
    }

    /// @dev The Usdy adapter reads the spec's source, and its scale comes from the 6- and 18-decimal tokens.
    function test_implementation_buildsTheUsdyAdapter() external {
        UsdyNavOracle adapter = UsdyNavOracle(harness.implementation(spec));
        assertEq(address(adapter.SOURCE()), address(getter), "SOURCE");
        assertEq(adapter.PRICE_SCALE(), 1e6, "PRICE_SCALE");
        assertEq(
            address(adapter).codehash,
            address(new UsdyNavOracle(address(getter), spec.loanToken, spec.collateralToken)).codehash,
            "codehash"
        );
    }

    /// @dev Each Centrifuge field of the spec lands in its own immutable.
    function test_implementation_buildsTheCentrifugeAdapter() external {
        (MockCentrifugeSpoke spoke, TrailingAnchorPriceFeedSpec memory s) = _centrifugeSpec();
        CentrifugeNavOracle adapter = CentrifugeNavOracle(harness.implementation(s));
        assertEq(address(adapter.SPOKE()), address(spoke), "SPOKE");
        assertEq(adapter.POOL_ID(), s.poolId, "POOL_ID");
        assertEq(adapter.SHARE_CLASS_ID(), s.shareClassId, "SHARE_CLASS_ID");
        assertEq(adapter.MAX_PRICE_AGE(), 3 days, "MAX_PRICE_AGE");
        assertEq(adapter.PRICE_SCALE(), 1e18, "PRICE_SCALE");
    }

    /// @dev The build runs the adapter's own share token check, so a spec whose collateral is not the share token of
    ///      its pool builds no reference.
    function testRevert_implementation_centrifugeCollateralIsNotTheShareToken() external {
        (, TrailingAnchorPriceFeedSpec memory s) = _centrifugeSpec();
        address share = s.collateralToken;
        s.collateralToken = spec.collateralToken;
        vm.expectRevert(
            abi.encodeWithSelector(CentrifugeNavOracle.ShareTokenMismatch.selector, share, spec.collateralToken)
        );
        harness.implementation(s);
    }

    function test_checks_takeTheLaunchState() external view {
        harness.checkLaunch(address(nav), spec, agent);
        harness.checkLive(address(nav), LLTV);
    }

    /// @dev Each of the eight parameters is compared with the oracle's own value, under its own name.
    function testRevert_checkLaunch_parameterMismatch() external {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxPriceAboveAnchor = 0.0004e18;
        _expectParameterMismatch(p, "maxPriceAboveAnchor", 0.0004e18, TrailingAnchorOracleModel.MAX_PRICE_ABOVE_ANCHOR);
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxPriceBelowAnchor = 0.002e18;
        _expectParameterMismatch(p, "maxPriceBelowAnchor", 0.002e18, TrailingAnchorOracleModel.MAX_PRICE_BELOW_ANCHOR);
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorContinuousRiseRate = 0.07e18;
        _expectParameterMismatch(
            p, "maxAnchorContinuousRiseRate", 0.07e18, TrailingAnchorOracleModel.MAX_ANCHOR_CONTINUOUS_RISE_RATE
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorContinuousFallRate = 0.02e18;
        _expectParameterMismatch(
            p, "maxAnchorContinuousFallRate", 0.02e18, TrailingAnchorOracleModel.MAX_ANCHOR_CONTINUOUS_FALL_RATE
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorBelowBase = 0.005e18;
        _expectParameterMismatch(p, "maxAnchorBelowBase", 0.005e18, TrailingAnchorOracleModel.MAX_ANCHOR_BELOW_BASE);
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveBase = 0.001e18;
        _expectParameterMismatch(p, "maxAnchorAboveBase", 0.001e18, TrailingAnchorOracleModel.MAX_ANCHOR_ABOVE_BASE);
        p = TrailingAnchorOracleModel.defaultParameters();
        p.reanchorDelay = 7 hours;
        _expectParameterMismatch(p, "reanchorDelay", 7 hours, TrailingAnchorOracleModel.REANCHOR_DELAY);
        p = TrailingAnchorOracleModel.defaultParameters();
        p.reanchorWindow = 2 days;
        _expectParameterMismatch(p, "reanchorWindow", 2 days, TrailingAnchorOracleModel.REANCHOR_WINDOW);
    }

    /// @dev A second holder of any role is refused: a deployer left as admin, a second manager or price acceptor.
    function testRevert_checkLaunch_extraRoleHolder() external {
        bytes32[3] memory roles = _roles();
        for (uint256 i; i < roles.length; ++i) {
            TrailingAnchorOracleBase oracle = _launch();
            vm.prank(agent);
            oracle.grantRole(roles[i], other);
            vm.expectRevert(
                abi.encodeWithSelector(TrailingAnchorPriceFeed.RoleHolderCountMismatch.selector, roles[i], 1, 2)
            );
            harness.checkLaunch(address(oracle), spec, agent);
        }
    }

    /// @dev A role that nobody holds is refused.
    function testRevert_checkLaunch_missingRoleHolder() external {
        bytes32[3] memory roles = _roles();
        for (uint256 i; i < roles.length; ++i) {
            TrailingAnchorOracleBase oracle = _launch();
            vm.prank(agent);
            oracle.renounceRole(roles[i], agent);
            vm.expectRevert(
                abi.encodeWithSelector(TrailingAnchorPriceFeed.RoleHolderCountMismatch.selector, roles[i], 1, 0)
            );
            harness.checkLaunch(address(oracle), spec, agent);
        }
    }

    /// @dev A role whose only holder is not the Agent is refused, with that holder named.
    function testRevert_checkLaunch_otherRoleHolder() external {
        bytes32[3] memory roles = _roles();
        for (uint256 i; i < roles.length; ++i) {
            TrailingAnchorOracleBase oracle = _launch();
            vm.startPrank(agent);
            oracle.grantRole(roles[i], other);
            oracle.renounceRole(roles[i], agent);
            vm.stopPrank();
            vm.expectRevert(
                abi.encodeWithSelector(TrailingAnchorPriceFeed.RoleHolderUnexpected.selector, roles[i], other)
            );
            harness.checkLaunch(address(oracle), spec, agent);
        }
    }

    /// @dev The working 1% floor and 0.2% ceiling fit a 98% LLTV and not 98.2%. There LIF = 1 / (1 − 0.3 × 0.018)
    ///      and LLTV × LIF × 1.0005 = 0.987825…, which leaves a ceiling of 0.1199% over the 0.99 × 0.999 of the
    ///      floor.
    function testRevert_checkLive_corridorTooWideForTheLltv() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorPriceFeed.CorridorTooWide.selector, 0.01e18, 0.002e18, 0.982e18, 1_199_345_337_514_542
            )
        );
        harness.checkLive(address(nav), 0.982e18);
    }

    /// @dev The sizing rule runs on the live parameters, not on a spec: after `setParameters` narrows the ceiling to
    ///      0.1%, the oracle fits 98.2%.
    function test_checkLive_readsTheLiveParameters() external {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveBase = 0.001e18;
        vm.prank(agent);
        nav.setParameters(p);
        harness.checkLive(address(nav), 0.982e18);
    }

    /// @dev A market at a lower LLTV passes: the corridor that fits 98% also fits 92%.
    function test_checkLive_takesALowerLltv() external view {
        harness.checkLive(address(nav), 0.92e18);
    }

    /// @dev After a drift down to 0.999, a floor set exactly on the anchor passes, and a floor one wei higher is
    ///      refused. With a base price of 1, the floor is 1 − maxAnchorBelowBase to the wei.
    function test_checkLive_anchorOnTheFloorAndOneWeiBelowIt() external {
        vm.warp(block.timestamp + 40 days);
        getter.setCurrentPrice(0.999e18);
        nav.updateAnchor();
        assertEq(nav.anchorPrice(), 0.999e18, "anchor drifted down");
        assertEq(nav.basePrice(), 1e18, "base price");

        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorBelowBase = 0.001e18;
        vm.prank(agent);
        nav.setParameters(p);
        harness.checkLive(address(nav), LLTV);

        p.maxAnchorBelowBase = 0.001e18 - 1;
        vm.prank(agent);
        nav.setParameters(p);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorPriceFeed.AnchorOutsideLines.selector, 0.999e18, 0.999e18 + 1, 1.002e18
            )
        );
        harness.checkLive(address(nav), LLTV);
    }

    /// @dev A re-anchor up stops on the 1.002 ceiling and passes; a ceiling one wei lower is refused.
    function test_checkLive_anchorOnTheCeilingAndOneWeiAboveIt() external {
        getter.setCurrentPrice(1.5e18);
        nav.updateAnchor();
        vm.warp(block.timestamp + TrailingAnchorOracleModel.REANCHOR_DELAY);
        nav.updateAnchor();
        assertEq(nav.anchorPrice(), 1.002e18, "anchor on the ceiling");
        assertEq(nav.basePrice(), 1e18, "base price");
        harness.checkLive(address(nav), LLTV);

        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveBase = 0.002e18 - 1;
        vm.prank(agent);
        nav.setParameters(p);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorPriceFeed.AnchorOutsideLines.selector, 1.002e18, 0.99e18, 1.002e18 - 1)
        );
        harness.checkLive(address(nav), LLTV);
    }

    // ---
    // HELPERS
    // ---

    /// @dev The launch state: the Agent initializes the oracle at $1.00 and holds each role alone.
    function _launch() internal returns (TrailingAnchorOracleBase oracle) {
        bytes memory init =
            TrailingAnchorOracleModel.initializeCall(agent, spec.parameters, spec.seedMinPrice, spec.seedMaxPrice);
        oracle = TrailingAnchorOracleBase(address(new OssifiableProxy(harness.implementation(spec), agent, init)));
        vm.startPrank(agent);
        oracle.grantRole(oracle.MANAGER_ROLE(), agent);
        oracle.grantRole(oracle.PRICE_ACCEPTOR_ROLE(), agent);
        vm.stopPrank();
    }

    function _roles() internal view returns (bytes32[3] memory) {
        return [nav.DEFAULT_ADMIN_ROLE(), nav.MANAGER_ROLE(), nav.PRICE_ACCEPTOR_ROLE()];
    }

    function _centrifugeSpec() internal returns (MockCentrifugeSpoke spoke, TrailingAnchorPriceFeedSpec memory s) {
        uint64 poolId = 281474976710662;
        bytes16 shareClassId = 0x00010000000000060000000000000001;
        MockERC20 share = new MockERC20("JTRSY", "JTRSY", 6);
        spoke = new MockCentrifugeSpoke(poolId, shareClassId, address(share));
        spoke.setCurrentPrice(1e18);
        s = spec;
        s.kind = TrailingAnchorKind.Centrifuge;
        s.source = address(spoke);
        s.poolId = poolId;
        s.shareClassId = shareClassId;
        s.maxPriceAge = 3 days;
        s.collateralToken = address(share);
    }

    /// @dev Checks the launched oracle against the spec with `p` in place of its parameters.
    function _expectParameterMismatch(
        TrailingAnchorOracleBase.Parameters memory p,
        bytes32 field,
        uint256 expected,
        uint256 actual
    ) internal {
        TrailingAnchorPriceFeedSpec memory s = spec;
        s.parameters = p;
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorPriceFeed.ParameterMismatch.selector, field, expected, actual)
        );
        harness.checkLaunch(address(nav), s, agent);
    }
}

/// @notice The sizing rule at the market's LLTV. The expected edges come from the spec's sizing formula, written out
///         here, not from the library.
contract TrailingAnchorPriceFeedSizingTest is Test {
    uint256 internal constant WAD = 1e18;
    /// @dev The library rounds the needed side up and the room side down, so it may refuse a line up to this many wei
    ///      inside the edge of the rule. In wei of a whole price, the two ceilings on the needed side add less than
    ///      (1 + above)(1 + ceiling) + (1 + ceiling). The floor on the room and the last ceiling add less than 1
    ///      together, since an integer is below ceil(y) only if it is below y. A ceiling k wei inside the edge leaves
    ///      k × LLTV × LIF × (1 + above) of room, so a refusal needs that sum to be more. The edge stays
    ///      under a whole price, so LLTV × LIF × (1 + above) is at least half the room, and k is at most 10. The
    ///      floor needs only 3.
    uint256 internal constant MAX_ROUNDING_GAP = 10;

    TrailingAnchorPriceFeedHarness internal harness;

    function setUp() public {
        harness = new TrailingAnchorPriceFeedHarness();
    }

    /// @dev The largest `maxAnchorAboveBase` the sizing rule leaves over each class's floor, by the spec's
    ///      formula: 0.26% at a 98% LLTV with bounds of +0.05% and −0.1% and a 1% floor, 0.31% at ±0.05%, 0.21% at
    ///      ±0.1%, and 1.23% at 92% with ±0.3% and 4%. Each edge passes, and one wei more is refused.
    function test_requireSizing_largestAboveBaseIsTheEdge() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        _assertAboveBaseEdge(p, 0.98e18, 0.0026e18, "0.26% at 98%");
        p.maxPriceBelowAnchor = 0.0005e18;
        _assertAboveBaseEdge(p, 0.98e18, 0.0031e18, "0.31% at 98% with 0.05% bounds");
        p.maxPriceAboveAnchor = 0.001e18;
        p.maxPriceBelowAnchor = 0.001e18;
        _assertAboveBaseEdge(p, 0.98e18, 0.0021e18, "0.21% at 98% with 0.1% bounds");
        p.maxPriceAboveAnchor = 0.003e18;
        p.maxPriceBelowAnchor = 0.003e18;
        p.maxAnchorBelowBase = 0.04e18;
        _assertAboveBaseEdge(p, 0.92e18, 0.0123e18, "1.23% at 92% with 0.3% bounds and 4%");
    }

    /// @dev Under an LLTV of about 56.5% the core holds the liquidation incentive at 1.15. At 50% the rule needs
    ///      0.5 × 1.15 × 1.0005 = 0.5752875 of the 0.99 × 0.999 the floor leaves, so the ceiling may sit 71.92% over
    ///      the base price. With the incentive not held, 1 / 0.85, it would stop at 68.05%.
    function test_requireSizing_edgeWhereTheIncentiveIsHeld() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        _assertAboveBaseEdge(p, 0.5e18, 0.71916e18, "71.92% at 50%");
    }

    /// @dev The other way round: with the working 0.2% ceiling the rule allows a floor about 1.06% under the base
    ///      price at 98%, and with a 1% ceiling at 92% and ±0.3% bounds about 4.22%. Each edge passes, and one wei
    ///      deeper is refused.
    function test_requireSizing_largestBelowBaseIsTheEdge() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        uint256 largest = _largestBelowBase(p, 0.98e18);
        assertApproxEqAbs(largest, 0.0106e18, 0.00005e18, "1.06% at 98%");
        p.maxAnchorBelowBase = uint64(largest);
        harness.requireSizing(p, 0.98e18);
        p.maxAnchorBelowBase = uint64(largest + 1);
        _expectRefused(p, 0.98e18);

        p.maxPriceAboveAnchor = 0.003e18;
        p.maxPriceBelowAnchor = 0.003e18;
        p.maxAnchorAboveBase = 0.01e18;
        largest = _largestBelowBase(p, 0.92e18);
        assertApproxEqAbs(largest, 0.0422e18, 0.00005e18, "4.22% at 92% with 0.3% bounds and 1%");
        p.maxAnchorBelowBase = uint64(largest);
        harness.requireSizing(p, 0.92e18);
        p.maxAnchorBelowBase = uint64(largest + 1);
        _expectRefused(p, 0.92e18);
    }

    /// @dev Any LLTV and any corridor: the library takes the parameters only if the lowest price the oracle can
    ///      return covers a debt borrowed at the LLTV against the highest, with the core's incentive on top, and
    ///      refuses them only if it does not. The inequality is checked in whole numbers with no division, so it shares
    ///      no rounding with the library; the two may differ by the few wei the library rounds against the
    ///      corridor. Its rounding refuses a set up to 4.1 wei over the rule and takes one up to 3.7 wei under it.
    function testFuzz_requireSizing_takesACorridorOnlyIfItCoversTheLiquidation(
        uint256 lltv,
        uint64 above,
        uint64 below,
        uint64 belowBase,
        uint64 aboveBase
    ) public {
        lltv = bound(lltv, 0.3e18, 0.99e18);
        TrailingAnchorOracleBase.Parameters memory p;
        p.maxPriceAboveAnchor = uint64(bound(above, 1, 0.05e18));
        p.maxPriceBelowAnchor = uint64(bound(below, 1, 0.05e18));
        p.maxAnchorBelowBase = uint64(bound(belowBase, 0, 0.5e18));
        p.maxAnchorAboveBase = uint64(bound(aboveBase, 0, 0.5e18));

        try harness.requireSizing(p, lltv) {
            assertTrue(_covers(p, lltv, 0, 4), "taken, so the corridor covers the liquidation");
        } catch (bytes memory revertData) {
            assertEq(bytes4(revertData), TrailingAnchorPriceFeed.CorridorTooWide.selector, "refused by the rule");
            assertFalse(_covers(p, lltv, 5, 0), "refused, so the corridor does not cover the liquidation");
        }
    }

    /// @dev At the edge of the sizing rule: the fuzzer picks the LLTV, the bounds and one line, and the other line
    ///      sits near the widest value the spec's rule allows for them. The library refuses every set the rule
    ///      refuses, and refuses a set the rule takes only within `MAX_ROUNDING_GAP` of the edge.
    function testFuzz_requireSizing_edgeOfTheSizingRule(
        uint256 lltv,
        uint64 above,
        uint64 below,
        uint64 otherLine,
        bool solveCeiling,
        int256 offset
    ) public {
        lltv = bound(lltv, 0.3e18, 0.99e18);
        TrailingAnchorOracleBase.Parameters memory p;
        p.maxPriceAboveAnchor = uint64(bound(above, 1, 0.01e18));
        p.maxPriceBelowAnchor = uint64(bound(below, 1, 0.01e18));
        _setLine(p, !solveCeiling, bound(otherLine, 0, 0.05e18));
        uint256 edge = _widestLine(p, lltv, solveCeiling);
        vm.assume(edge >= 2 * MAX_ROUNDING_GAP && edge <= WAD - 10);
        offset = bound(offset, -2 * int256(MAX_ROUNDING_GAP), int256(MAX_ROUNDING_GAP));
        _setLine(p, solveCeiling, uint256(int256(edge) + offset));
        bool holds = TrailingAnchorOracleModel.sized(p, lltv);
        assertEq(holds, offset <= 0, "the rule holds up to the edge");

        try harness.requireSizing(p, lltv) {
            assertTrue(holds, "taken where the rule fails");
        } catch (bytes memory revertData) {
            assertEq(bytes4(revertData), TrailingAnchorPriceFeed.CorridorTooWide.selector, "refused by the rule");
            if (holds) {
                assertLe(uint256(-offset), MAX_ROUNDING_GAP, "refused further inside the edge than the rounding");
            }
        }
    }

    /// @dev A ceiling 9 wei inside the edge of the rule at a 43.16% LLTV: the rule takes it, and the library's
    ///      rounding refuses it.
    function test_requireSizing_ceilingNineWeiInsideTheEdgeIsWithinTheRounding() public {
        testFuzz_requireSizing_edgeOfTheSizingRule(
            431558710300315627, 1881934947331682, 7062787411673335, 24141113695334605, true, -9
        );
    }

    // ---
    // HELPERS
    // ---

    /// @dev `CorridorTooWide` for `p` at `lltv`.
    function _expectRefused(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv) internal {
        vm.expectPartialRevert(TrailingAnchorPriceFeed.CorridorTooWide.selector);
        harness.requireSizing(p, lltv);
    }

    /// @dev Checks that `p`'s largest `maxAnchorAboveBase` at `lltv` is about `expected`, that the library
    ///      takes it, and that it refuses one wei more and names the largest.
    function _assertAboveBaseEdge(
        TrailingAnchorOracleBase.Parameters memory p,
        uint256 lltv,
        uint256 expected,
        string memory label
    ) internal {
        uint256 largest = _largestAboveBase(p, lltv);
        assertApproxEqAbs(largest, expected, 0.00005e18, label);
        p.maxAnchorAboveBase = uint64(largest);
        harness.requireSizing(p, lltv);
        p.maxAnchorAboveBase = uint64(largest + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorPriceFeed.CorridorTooWide.selector, p.maxAnchorBelowBase, largest + 1, lltv, largest
            )
        );
        harness.requireSizing(p, lltv);
    }

    /// @dev The widest `maxAnchorAboveBase` the sizing rule allows, from the spec's formula: the highest price the
    ///      oracle returns, the ceiling × (1 + maxPriceAboveAnchor), times LLTV × LIF must stay under the lowest, the
    ///      floor × (1 − maxPriceBelowAnchor), with LIF rounded down as the core rounds it, and every other step
    ///      rounded against the corridor.
    function _largestAboveBase(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 room = (WAD - p.maxAnchorBelowBase) * (WAD - p.maxPriceBelowAnchor) / WAD;
        uint256 needed = _neededAtTheBasePrice(p, lltv);
        return room < needed ? 0 : room * WAD / needed - WAD;
    }

    /// @dev The widest `maxAnchorBelowBase` the sizing rule allows for `p`'s `maxAnchorAboveBase`, from the
    ///      same formula.
    function _largestBelowBase(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 needed = _ceilDiv(_neededAtTheBasePrice(p, lltv) * (WAD + p.maxAnchorAboveBase), WAD);
        return WAD - _ceilDiv(needed * WAD, WAD - p.maxPriceBelowAnchor);
    }

    /// @dev What the rule needs with the ceiling on the base price: LLTV × LIF × (1 + maxPriceAboveAnchor),
    ///      with LIF rounded down as the core rounds it, and each other step rounded up.
    function _neededAtTheBasePrice(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 lif = TrailingAnchorOracleModel.liquidationIncentive(lltv);
        return _ceilDiv(_ceilDiv(lltv * lif, WAD) * (WAD + p.maxPriceAboveAnchor), WAD);
    }

    /// @dev The sizing rule in whole numbers: (1 − below base)(1 − below anchor) ≥ LLTV × LIF × (1 + above
    ///      base)(1 + above anchor), with LIF = 10 / (7 + 3 × LLTV), or 1.15 where that is higher, and both sides
    ///      multiplied through. `slackFor` wei of a whole price are added to the left side and `slackAgainst` taken
    ///      from it.
    function _covers(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv, uint256 slackAgainst, uint256 slackFor)
        internal
        pure
        returns (bool)
    {
        uint256 room = (WAD - p.maxAnchorBelowBase) * (WAD - p.maxPriceBelowAnchor);
        uint256 reach = (WAD + p.maxAnchorAboveBase) * (WAD + p.maxPriceAboveAnchor);
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
        if (ceiling) p.maxAnchorAboveBase = uint64(value);
        else p.maxAnchorBelowBase = uint64(value);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
