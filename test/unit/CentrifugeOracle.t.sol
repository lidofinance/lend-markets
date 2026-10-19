// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {CentrifugeOracle} from "../../src/oracle/CentrifugeOracle.sol";
import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {MockERC20, MockUsdFeed} from "../setup/Mocks.sol";
import {NavOracleModel} from "../setup/NavOracleModel.sol";

/// @dev Centrifuge Spoke stand-in: a D18 share price per pool and share class. It refuses an unknown share class and a
///      read that asks for the validity check, so a price comes back only for the exact call the oracle must make.
contract MockSpoke {
    error ShareTokenDoesNotExist();
    error ValidityCheckRequested();

    mapping(uint64 poolId => mapping(bytes16 scId => uint128)) public prices;

    function setPrice(uint64 poolId, bytes16 scId, uint128 price) external {
        prices[poolId][scId] = price;
    }

    function pricePoolPerShare(uint64 poolId, bytes16 scId, bool checkValidity) external view returns (uint128) {
        if (checkValidity) revert ValidityCheckRequested();
        uint128 price = prices[poolId][scId];
        if (price == 0) revert ShareTokenDoesNotExist();
        return price;
    }
}

/// @notice `CentrifugeOracle` reads the Spoke's D18 share price for one pool and share class, without the Spoke's
///         validity check, and scales it to the market's tokens.
contract CentrifugeOracleTest is Test {
    uint64 internal constant JTRSY_POOL = 281474976710662;
    bytes16 internal constant JTRSY_SC = 0x00010000000000060000000000000001;
    /// @dev `pricePoolPerShare` for JTRSY on 2026-10-15.
    uint128 internal constant JTRSY_PRICE = 1.119208554380295602e18;

    MockSpoke internal spoke;
    MockUsdFeed internal feed;
    MockERC20 internal usdc;

    function setUp() public {
        vm.warp(1_760_000_000);
        spoke = new MockSpoke();
        feed = new MockUsdFeed();
        usdc = new MockERC20("USDC", "USDC", 6);
        spoke.setPrice(JTRSY_POOL, JTRSY_SC, JTRSY_PRICE);
    }

    function testRevert_constructor_zeroSpoke() public {
        MockERC20 share = new MockERC20("JTRSY", "JTRSY", 6);
        vm.expectRevert(NavOracleBase.ZeroAddress.selector);
        new CentrifugeOracle(address(0), JTRSY_POOL, JTRSY_SC, address(usdc), address(share), address(feed));
    }

    /// @dev A 6-decimal share in a 6-decimal market scales by 1e18: one base unit of share is 1.119 base units of USDC.
    function test_price_sixDecimalShare() public {
        CentrifugeOracle oracle = _deploy(JTRSY_POOL, JTRSY_SC, 6);
        assertEq(address(oracle.SPOKE()), address(spoke), "SPOKE");
        assertEq(oracle.POOL_ID(), JTRSY_POOL, "POOL_ID");
        assertEq(oracle.SHARE_CLASS_ID(), JTRSY_SC, "SHARE_CLASS_ID");
        assertEq(oracle.PRICE_SCALE(), 1e18, "PRICE_SCALE");
        assertEq(oracle.price(), uint256(JTRSY_PRICE) * 1e18, "price");
    }

    /// @dev Any share decimals up to 18 above the loan token's: the price is the share price times
    ///      `10^(36 + 6 − shareDecimals − 18)`.
    function testFuzz_price_scalesToShareDecimals(uint8 shareDecimals, uint128 sharePrice) public {
        shareDecimals = uint8(bound(shareDecimals, 0, 24));
        sharePrice = uint128(bound(sharePrice, 1, type(uint128).max));
        spoke.setPrice(JTRSY_POOL, JTRSY_SC, sharePrice);
        CentrifugeOracle oracle = _deploy(JTRSY_POOL, JTRSY_SC, shareDecimals);
        uint256 scale = 10 ** (24 - uint256(shareDecimals));
        assertEq(oracle.PRICE_SCALE(), scale, "PRICE_SCALE");
        assertEq(oracle.price(), uint256(sharePrice) * scale, "price");
    }

    /// @dev The pool and share class come from the constructor: another share class's price is not read.
    function testRevert_price_unknownShareClass() public {
        CentrifugeOracle impl = new CentrifugeOracle(
            address(spoke), JTRSY_POOL, bytes16(uint128(JTRSY_SC) + 1), address(usdc), address(usdc), address(feed)
        );
        bytes memory init =
            abi.encodeCall(NavOracleBase.initialize, (address(this), NavOracleModel.workingDefaults(0.035e18)));
        vm.expectRevert(MockSpoke.ShareTokenDoesNotExist.selector);
        new OssifiableProxy(address(impl), address(this), init);
    }

    function _deploy(uint64 poolId, bytes16 scId, uint8 shareDecimals) internal returns (CentrifugeOracle) {
        MockERC20 share = new MockERC20("Share", "SHARE", shareDecimals);
        CentrifugeOracle impl =
            new CentrifugeOracle(address(spoke), poolId, scId, address(usdc), address(share), address(feed));
        bytes memory init =
            abi.encodeCall(NavOracleBase.initialize, (address(this), NavOracleModel.workingDefaults(0.035e18)));
        return CentrifugeOracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }
}
