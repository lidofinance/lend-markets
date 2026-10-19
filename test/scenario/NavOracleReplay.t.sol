// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {UsdyOracle} from "../../src/oracle/UsdyOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {MockERC20, MockNavOracle, MockUsdFeed} from "../setup/Mocks.sol";
import {NavOracleModel, NavOracleState} from "../setup/NavOracleModel.sol";

/// @notice I11: the recorded daily USDY, JAAA and JTRSY series from 2025-09-24 to 2026-10-14 replayed through the
/// oracle with the working defaults. With a keeper that re-anchors when allowed and checkpoints every day, no day
///         reverts, the price is the source on every day, the reference moves on a fixed cadence, and the floor trails
///         one step under the last checkpoint, under every dip. Without any keeper the series still never reverts.
/// @dev The oracle runs alone with a `PRICE_SCALE` of one, so a source price is the 18-decimal NAV. The series and its
///      precision come from `test/fixtures/nav-oracle/`.
contract NavOracleReplayTest is Test {
    using NavOracleModel for NavOracleState;

    string internal constant SERIES = "test/fixtures/nav-oracle/daily-series-2025-09-24-to-2026-10-14.int.json";
    /// @dev 2025-09-24 12:00 UTC, the series' first sample.
    uint256 internal constant START = 1_758_715_200;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant STEP = 0.0025e18;

    MockNavOracle internal source;
    UsdyOracle internal oracle;

    function test_replay_usdy() public {
        uint256[4] memory moves = [uint256(90), 180, 270, 360];
        _replayWithKeeper("USDY", 0.0375e18, moves);
    }

    /// @dev JAAA's March 2026 dip holds the source more than one tolerance under the path on days 180 and 181, so its
    ///      re-anchors land two days later than the other series'.
    function test_replay_jaaa() public {
        uint256[4] memory moves = [uint256(90), 182, 272, 362];
        _replayWithKeeper("JAAA", 0.0425e18, moves);
    }

    function test_replay_jtrsy() public {
        uint256[4] memory moves = [uint256(90), 180, 270, 360];
        _replayWithKeeper("JTRSY", 0.035e18, moves);
    }

    /// @dev JAAA's largest daily fall, −0.208% on 2026-03-04, sits inside one floor step, so the floor stays under
    /// it.
    function test_replay_jaaaLargestDipPassesInOneStep() public {
        uint256[] memory series = _series("JAAA");
        uint256 dip = 161;
        assertLt(series[dip], series[dip - 1], "a fall");
        assertGt(series[dip], Math.mulDiv(series[dip - 1], WAD - STEP, WAD), "inside one step");
        assertEq(Math.mulDiv(series[dip - 1] - series[dip], 1e6, series[dip - 1]), 2079, "-0.208%");
    }

    /// @dev Nobody calls anything for the whole series: the floor falls away from the first checkpoint and the price
    ///      is the rule over the initial state on every day, with no revert.
    function test_replayWithoutKeeper_neverReverts() public {
        _replayWithoutKeeper("USDY", 0.0375e18);
        _replayWithoutKeeper("JAAA", 0.0425e18);
        _replayWithoutKeeper("JTRSY", 0.035e18);
    }

    function _replayWithKeeper(string memory asset, uint256 rate, uint256[4] memory expectedMoves) internal {
        uint256[] memory series = _series(asset);
        _deploy(series[0], rate);
        uint256 moveCount;
        for (uint256 day = 1; day < series.length; ++day) {
            vm.warp(START + day * 1 days);
            source.setPrice(series[day]);
            NavOracleState memory s = NavOracleModel.read(oracle);

            // The floor before the day's calls is one step under the last checkpoint, which the keeper set to the
            // lower of yesterday's source and path, and it never reaches today's source.
            uint256 floor_ = s.floor(block.timestamp);
            assertEq(floor_, Math.mulDiv(s.checkpointPrice, WAD - STEP, WAD), "floor is one step under the checkpoint");
            assertLe(floor_, series[day], "the floor held an honest source");

            if (_moveAllowed(s, series[day])) {
                oracle.moveReferencePrice();
                assertEq(day, expectedMoves[moveCount], "re-anchor day");
                ++moveCount;
            }
            uint256 expected = NavOracleModel.read(oracle).expectedPrice(block.timestamp);
            oracle.checkpoint();
            assertEq(oracle.checkpointPrice(), Math.min(series[day], expected), "checkpoint trails the source");
            assertEq(oracle.price(), series[day], "the price is the source");
        }
        assertEq(moveCount, 4, "four re-anchors");
    }

    function _replayWithoutKeeper(string memory asset, uint256 rate) internal {
        uint256[] memory series = _series(asset);
        _deploy(series[0], rate);
        NavOracleState memory s = NavOracleModel.read(oracle);
        for (uint256 day = 1; day < series.length; ++day) {
            vm.warp(START + day * 1 days);
            source.setPrice(series[day]);
            assertTrue(s.inBand(series[day], block.timestamp), "inside the band");
            assertEq(oracle.price(), s.boundedPrice(series[day], block.timestamp), "the rule over the initial state");
        }
    }

    function _moveAllowed(NavOracleState memory s, uint256 sourcePrice) internal view returns (bool) {
        uint256 lowest = Math.mulDiv(s.expectedPrice(block.timestamp), WAD - s.params.growthTolerance, WAD);
        return block.timestamp - s.referencePriceSetAt >= s.params.referenceInterval && sourcePrice >= lowest
            && sourcePrice >= s.floor(block.timestamp) && sourcePrice <= s.upperBound(block.timestamp);
    }

    function _deploy(uint256 initialNav, uint256 rate) internal {
        vm.warp(START);
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 36);
        MockUsdFeed feed = new MockUsdFeed();
        source = new MockNavOracle();
        source.setPrice(initialNav);
        UsdyOracle impl = new UsdyOracle(address(source), address(loan), address(collateral), address(feed));
        bytes memory init =
            abi.encodeCall(NavOracleBase.initialize, (address(this), NavOracleModel.workingDefaults(rate)));
        oracle = UsdyOracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }

    /// @dev The asset's series as 18-decimal NAVs.
    function _series(string memory asset) internal view returns (uint256[] memory series) {
        string memory json = vm.readFile(SERIES);
        uint256 decimals = vm.parseJsonUint(json, string.concat(".decimals.", asset));
        series = vm.parseJsonUintArray(json, string.concat(".series.", asset));
        for (uint256 i; i < series.length; ++i) {
            series[i] *= 10 ** (18 - decimals);
        }
        assertEq(series.length, 386, "386 days");
    }
}
