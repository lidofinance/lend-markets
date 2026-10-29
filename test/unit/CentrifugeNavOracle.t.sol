// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {MockCentrifugeSpoke} from "../setup/NavSourceMocks.sol";

/// @notice `CentrifugeNavOracle` reads the Spoke's D18 share price for one pool and share class, without the Spoke's
///         validity check, as its current price. The anchor rules run through this adapter in
///         `TrailingAnchorOracleBase.t.sol`.
contract CentrifugeNavOracleTest is Test {
    uint64 internal constant JTRSY_POOL = 281474976710662;
    bytes16 internal constant JTRSY_SC = 0x00010000000000060000000000000001;
    /// @dev `pricePoolPerShare` for JTRSY on 2026-10-15.
    uint128 internal constant JTRSY_PRICE = 1.119208554380295602e18;

    MockCentrifugeSpoke internal spoke;
    MockERC20 internal usdc;

    function setUp() public {
        vm.warp(1_760_000_000);
        spoke = new MockCentrifugeSpoke(JTRSY_POOL, JTRSY_SC);
        spoke.setCurrentPrice(JTRSY_PRICE);
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    function testRevert_constructor_zeroAddresses() public {
        MockERC20 share = new MockERC20("JTRSY", "JTRSY", 6);
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new CentrifugeNavOracle(address(0), JTRSY_POOL, JTRSY_SC, address(usdc), address(share));
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new CentrifugeNavOracle(address(spoke), JTRSY_POOL, JTRSY_SC, address(usdc), address(0));
    }

    /// @dev A 6-decimal share in a 6-decimal market scales by 1e18: one base unit of share is 1.119 base units of USDC.
    ///      The mock refuses a read that asks for the validity check, so a price at all means the oracle skipped it.
    function test_price_sixDecimalShare() public {
        CentrifugeNavOracle oracle = _deploy(JTRSY_SC, 6);
        assertEq(address(oracle.SPOKE()), address(spoke), "SPOKE");
        assertEq(oracle.POOL_ID(), JTRSY_POOL, "POOL_ID");
        assertEq(oracle.SHARE_CLASS_ID(), JTRSY_SC, "SHARE_CLASS_ID");
        assertEq(oracle.PRICE_SCALE(), 1e18, "PRICE_SCALE");
        assertEq(oracle.price(), uint256(JTRSY_PRICE) * 1e18, "price");
        assertEq(oracle.anchorPrice(), JTRSY_PRICE, "anchor is the D18 share price");
        vm.expectRevert(MockCentrifugeSpoke.ValidityCheckRequested.selector);
        spoke.pricePoolPerShare(JTRSY_POOL, JTRSY_SC, true);
    }

    /// @dev Any share decimals up to 18 above the loan token's: the price is the share price times
    ///      `10^(36 + 6 − shareDecimals − 18)`.
    function testFuzz_price_scalesToShareDecimals(uint8 shareDecimals, uint128 sharePrice) public {
        shareDecimals = uint8(bound(shareDecimals, 0, 24));
        sharePrice = uint128(bound(sharePrice, 1, type(uint128).max));
        spoke.setCurrentPrice(sharePrice);
        CentrifugeNavOracle oracle = _deploy(JTRSY_SC, shareDecimals);
        uint256 scale = TrailingAnchorOracleModel.priceScale(6, shareDecimals);
        assertEq(oracle.PRICE_SCALE(), scale, "PRICE_SCALE");
        assertEq(oracle.price(), uint256(sharePrice) * scale, "price");
    }

    /// @dev The pool and share class come from the constructor: another share class's price is not read.
    function testRevert_initialize_otherShareClass() public {
        MockERC20 share = new MockERC20("Share", "SHARE", 6);
        CentrifugeNavOracle impl = new CentrifugeNavOracle(
            address(spoke), JTRSY_POOL, bytes16(uint128(JTRSY_SC) + 1), address(usdc), address(share)
        );
        bytes memory init = TrailingAnchorOracleModel.initializeCall(address(this));
        vm.expectRevert(MockCentrifugeSpoke.ShareTokenDoesNotExist.selector);
        new OssifiableProxy(address(impl), address(this), init);
    }

    function _deploy(bytes16 scId, uint8 shareDecimals) internal returns (CentrifugeNavOracle) {
        MockERC20 share = new MockERC20("Share", "SHARE", shareDecimals);
        CentrifugeNavOracle impl =
            new CentrifugeNavOracle(address(spoke), JTRSY_POOL, scId, address(usdc), address(share));
        bytes memory init = TrailingAnchorOracleModel.initializeCall(address(this));
        return CentrifugeNavOracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }
}
