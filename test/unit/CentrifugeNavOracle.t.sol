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
///         validity check, as its current price, and refuses one older than `MAX_PRICE_AGE`. The anchor rules run
///         through this adapter in `TrailingAnchorOracleBase.t.sol`.
contract CentrifugeNavOracleTest is Test {
    uint64 internal constant JTRSY_POOL = 281474976710662;
    bytes16 internal constant JTRSY_SC = 0x00010000000000060000000000000001;
    /// @dev `pricePoolPerShare` for JTRSY on 2026-10-15.
    uint128 internal constant JTRSY_PRICE = 1.119208554380295602e18;
    /// @dev The oldest JTRSY and JAAA prices from February to November 2026 were about 131 hours old.
    uint256 internal constant MAX_PRICE_AGE = 7 days;

    MockCentrifugeSpoke internal spoke;
    MockERC20 internal usdc;
    MockERC20 internal jtrsy;

    function setUp() public {
        vm.warp(1_760_000_000);
        jtrsy = new MockERC20("JTRSY", "JTRSY", 6);
        spoke = new MockCentrifugeSpoke(JTRSY_POOL, JTRSY_SC, address(jtrsy));
        spoke.setCurrentPrice(JTRSY_PRICE);
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    /// @dev The live Spoke returns three markers: the stamp, the maximum age and the end of validity. The end of
    ///      validity is the stamp plus the maximum age, and it saturates when the maximum age is unbounded.
    function test_spokeMarkers_matchTheLiveTuple() public {
        (bool ok, bytes memory returned) = address(spoke)
            .staticcall(abi.encodeWithSelector(spoke.markersPricePoolPerShare.selector, JTRSY_POOL, JTRSY_SC));
        assertTrue(ok, "markers call");
        assertEq(returned.length, 96, "three words");
        (uint64 computedAt, uint64 maxAge, uint64 validUntil) = abi.decode(returned, (uint64, uint64, uint64));
        assertEq(computedAt, block.timestamp, "stamp");
        assertEq(maxAge, type(uint64).max, "unbounded maximum age");
        assertEq(validUntil, type(uint64).max, "saturated end of validity");
    }

    function testRevert_constructor_zeroAddresses() public {
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new CentrifugeNavOracle(address(0), JTRSY_POOL, JTRSY_SC, MAX_PRICE_AGE, address(usdc), address(jtrsy), 0);
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new CentrifugeNavOracle(address(spoke), JTRSY_POOL, JTRSY_SC, MAX_PRICE_AGE, address(usdc), address(0), 0);
    }

    function testRevert_constructor_zeroMaxPriceAge() public {
        vm.expectRevert(CentrifugeNavOracle.ZeroMaxPriceAge.selector);
        new CentrifugeNavOracle(address(spoke), JTRSY_POOL, JTRSY_SC, 0, address(usdc), address(jtrsy), 0);
    }

    /// @dev A share class whose token on the Spoke is not the collateral token is refused: 1,000 JTRSY must not be
    ///      priced at the NAV of another class.
    function testRevert_constructor_shareTokenMismatch() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 6);
        vm.expectRevert(
            abi.encodeWithSelector(CentrifugeNavOracle.ShareTokenMismatch.selector, address(jtrsy), address(other))
        );
        new CentrifugeNavOracle(address(spoke), JTRSY_POOL, JTRSY_SC, MAX_PRICE_AGE, address(usdc), address(other), 0);
    }

    /// @dev A price exactly `MAX_PRICE_AGE` old is returned; one second older is refused, by `price()` and by
    ///      `updateAnchor()`, with the time the Spoke computed it.
    function test_price_maxPriceAgeEdge() public {
        CentrifugeNavOracle oracle = _deploy(6);
        spoke.setPriceAge(MAX_PRICE_AGE);
        assertEq(oracle.price(), uint256(JTRSY_PRICE) * 1e18, "a price on the edge");
        spoke.setPriceAge(MAX_PRICE_AGE + 1);
        uint64 computedAt = uint64(block.timestamp - MAX_PRICE_AGE - 1);
        vm.expectRevert(abi.encodeWithSelector(CentrifugeNavOracle.StalePrice.selector, computedAt));
        oracle.price();
        vm.expectRevert(abi.encodeWithSelector(CentrifugeNavOracle.StalePrice.selector, computedAt));
        oracle.updateAnchor();
    }

    /// @dev The issuer supplies the stamp, so it can be later than the block. A price stamped at the block time is
    ///      returned; one stamped a second later is refused by name, by `price()` and by `updateAnchor()`.
    function testRevert_price_stampAfterTheBlock() public {
        CentrifugeNavOracle oracle = _deploy(6);
        assertEq(oracle.price(), uint256(JTRSY_PRICE) * 1e18, "a price stamped at the block time");
        spoke.setPriceAhead(1);
        uint64 computedAt = uint64(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CentrifugeNavOracle.PriceFromFuture.selector, computedAt));
        oracle.price();
        vm.expectRevert(abi.encodeWithSelector(CentrifugeNavOracle.PriceFromFuture.selector, computedAt));
        oracle.updateAnchor();
    }

    /// @dev A stale price is no seed and no accepted price: `initialize` and `acceptPrice()` refuse it as `price()`
    ///      does.
    function testRevert_seedAndAcceptance_stalePrice() public {
        CentrifugeNavOracle oracle = _deploy(6);
        bytes32 acceptorRole = oracle.PRICE_ACCEPTOR_ROLE();
        oracle.grantRole(acceptorRole, address(this));
        spoke.setPriceAge(MAX_PRICE_AGE + 1);
        bytes memory stale = abi.encodeWithSelector(
            CentrifugeNavOracle.StalePrice.selector, uint64(block.timestamp - MAX_PRICE_AGE - 1)
        );
        vm.expectRevert(stale);
        oracle.acceptPrice(0, type(uint256).max);

        address impl = OssifiableProxy(payable(address(oracle))).proxy__getImplementation();
        bytes memory init = TrailingAnchorOracleModel.initializeCall(address(this));
        vm.expectRevert(stale);
        new OssifiableProxy(impl, address(this), init);
    }

    /// @dev The adapter hands `maxLltv` to the base and keeps `maxPriceAge` for itself: two different values land in
    ///      their own getters, and a `maxLltv` of a whole price is refused.
    function test_constructor_maxLltvAndMaxPriceAge() public {
        CentrifugeNavOracle impl = new CentrifugeNavOracle(
            address(spoke), JTRSY_POOL, JTRSY_SC, 3 days, address(usdc), address(jtrsy), 0.98e18
        );
        assertEq(impl.MAX_LLTV(), 0.98e18, "MAX_LLTV");
        assertEq(impl.MAX_PRICE_AGE(), 3 days, "MAX_PRICE_AGE");
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidMaxLltv.selector, 1e18));
        new CentrifugeNavOracle(address(spoke), JTRSY_POOL, JTRSY_SC, 3 days, address(usdc), address(jtrsy), 1e18);
    }

    /// @dev A 6-decimal share in a 6-decimal market scales by 1e18: one base unit of share is 1.119 base units of USDC.
    ///      The mock refuses a read that asks for the validity check, so a price at all means the oracle skipped it.
    function test_price_sixDecimalShare() public {
        CentrifugeNavOracle oracle = _deploy(6);
        assertEq(address(oracle.SPOKE()), address(spoke), "SPOKE");
        assertEq(oracle.POOL_ID(), JTRSY_POOL, "POOL_ID");
        assertEq(oracle.SHARE_CLASS_ID(), JTRSY_SC, "SHARE_CLASS_ID");
        assertEq(oracle.MAX_PRICE_AGE(), MAX_PRICE_AGE, "MAX_PRICE_AGE");
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
        CentrifugeNavOracle oracle = _deploy(shareDecimals);
        uint256 scale = TrailingAnchorOracleModel.priceScale(6, shareDecimals);
        assertEq(oracle.PRICE_SCALE(), scale, "PRICE_SCALE");
        assertEq(oracle.price(), uint256(sharePrice) * scale, "price");
    }

    /// @dev The pool and share class come from the constructor: a share class the Spoke does not know is refused.
    function testRevert_constructor_otherShareClass() public {
        vm.expectRevert(MockCentrifugeSpoke.ShareTokenDoesNotExist.selector);
        new CentrifugeNavOracle(
            address(spoke), JTRSY_POOL, bytes16(uint128(JTRSY_SC) + 1), MAX_PRICE_AGE, address(usdc), address(jtrsy), 0
        );
    }

    function _deploy(uint8 shareDecimals) internal returns (CentrifugeNavOracle) {
        MockERC20 share = new MockERC20("Share", "SHARE", shareDecimals);
        spoke.setShareToken(address(share));
        CentrifugeNavOracle impl = new CentrifugeNavOracle(
            address(spoke), JTRSY_POOL, JTRSY_SC, MAX_PRICE_AGE, address(usdc), address(share), 0
        );
        bytes memory init = TrailingAnchorOracleModel.initializeCall(address(this));
        return CentrifugeNavOracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }
}
