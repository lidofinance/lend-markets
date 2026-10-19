// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ChainlinkNavOracle} from "../../src/oracle/ChainlinkNavOracle.sol";
import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {MockERC20, MockUsdFeed} from "../setup/Mocks.sol";
import {NavOracleModel} from "../setup/NavOracleModel.sol";

/// @dev Chainlink-shaped NAV feed with configurable decimals and a round time that never moves, so a price that
///      depends on `updatedAt` would show.
contract MockNavFeed {
    uint8 public immutable decimals;
    int256 public answer;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
    }

    function setAnswer(int256 answer_) external {
        answer = answer_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, 1, 1, 1);
    }
}

/// @notice `ChainlinkNavOracle` reads a NAV feed's answer, scales it from the feed's decimals to 18, ignores the
/// round's age and refuses a non-positive answer.
contract ChainlinkNavOracleTest is Test {
    MockUsdFeed internal pegFeed;
    MockERC20 internal usdc;
    MockERC20 internal share;

    function setUp() public {
        vm.warp(1_760_000_000);
        pegFeed = new MockUsdFeed();
        usdc = new MockERC20("USDC", "USDC", 6);
        share = new MockERC20("JTRSY", "JTRSY", 6);
    }

    function testRevert_constructor_zeroSource() public {
        vm.expectRevert(NavOracleBase.ZeroAddress.selector);
        new ChainlinkNavOracle(address(0), address(usdc), address(share), address(pegFeed));
    }

    function testRevert_constructor_feedDecimalsAbove18() public {
        MockNavFeed source = new MockNavFeed(19, 1e19);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.UnsupportedFeedDecimals.selector, 19));
        new ChainlinkNavOracle(address(source), address(usdc), address(share), address(pegFeed));
    }

    /// @dev The JTRSY NAVLink feed has 6 decimals: 1.119208 becomes 1.119208e18, then 1.119208e36 for a 6-decimal
    ///      share in a 6-decimal market, with a round time of 1 that is ignored.
    function test_price_navLinkExample() public {
        MockNavFeed source = new MockNavFeed(6, 1_119_208);
        ChainlinkNavOracle oracle = _deploy(source);
        assertEq(oracle.SOURCE_SCALE(), 1e12, "SOURCE_SCALE");
        assertEq(oracle.PRICE_SCALE(), 1e18, "PRICE_SCALE");
        assertEq(oracle.price(), 1.119208e36, "price");
    }

    function testFuzz_price_scalesFeedDecimals(uint8 feedDecimals, uint256 answer) public {
        feedDecimals = uint8(bound(feedDecimals, 0, 18));
        answer = bound(answer, 1, 1e30);
        MockNavFeed source = new MockNavFeed(feedDecimals, int256(answer));
        ChainlinkNavOracle oracle = _deploy(source);
        uint256 sourceScale = 10 ** (18 - uint256(feedDecimals));
        assertEq(oracle.SOURCE_SCALE(), sourceScale, "SOURCE_SCALE");
        assertEq(oracle.price(), answer * sourceScale * 1e18, "price");
    }

    function testRevert_price_nonPositiveAnswer() public {
        MockNavFeed source = new MockNavFeed(6, 1_119_208);
        ChainlinkNavOracle oracle = _deploy(source);
        source.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.InvalidAnswer.selector, int256(0)));
        oracle.price();
        source.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.InvalidAnswer.selector, int256(-1)));
        oracle.price();
    }

    function _deploy(MockNavFeed source) internal returns (ChainlinkNavOracle) {
        ChainlinkNavOracle impl =
            new ChainlinkNavOracle(address(source), address(usdc), address(share), address(pegFeed));
        bytes memory init =
            abi.encodeCall(NavOracleBase.initialize, (address(this), NavOracleModel.workingDefaults(0.035e18)));
        return ChainlinkNavOracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }
}
