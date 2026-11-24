// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {MockCentrifugeVault} from "../setup/NavSourceMocks.sol";

/// @notice `CentrifugeNavOracle` reads the share price in the loan token from the share token's Centrifuge vault, as
///         its current price, and refuses a vault price stamp older than `MAX_PRICE_AGE`. The anchor rules run through
///         this adapter in `TrailingAnchorOracleBase.t.sol`.
contract CentrifugeNavOracleTest is Test {
    /// @dev The JTRSY/USDC vault's `convertToAssets(1e18)` on 2026-11-24, equal to the Spoke's share price.
    uint128 internal constant JTRSY_PRICE = 1.123178812767625245e18;
    /// @dev The same vault's `pricePerShare()`, the price of one JTRSY in USDC units.
    uint256 internal constant JTRSY_PRICE_PER_SHARE = 1_123_178;
    /// @dev The oldest JTRSY and JAAA prices from February to November 2026 were about 131 hours old.
    uint256 internal constant MAX_PRICE_AGE = 7 days;

    MockCentrifugeVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal jtrsy;

    function setUp() public {
        vm.warp(1_760_000_000);
        jtrsy = new MockERC20("JTRSY", "JTRSY", 6);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockCentrifugeVault(address(jtrsy), address(usdc));
        vault.setCurrentPrice(JTRSY_PRICE);
    }

    /// @dev The mock converts as the live JTRSY/USDC vault did: one JTRSY is the price rounded down to USDC units, and
    ///      `10^18` JTRSY units are the 18-decimal price exactly. The stamp is the block time.
    function test_vaultMock_convertsLikeTheLiveVault() public view {
        assertEq(vault.convertToAssets(1e6), JTRSY_PRICE_PER_SHARE, "one share in USDC units");
        assertEq(vault.convertToAssets(1e18), JTRSY_PRICE, "1e12 shares in USDC units");
        assertEq(vault.priceLastUpdated(), block.timestamp, "stamp");
    }

    function testRevert_constructor_zeroAddresses() public {
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new CentrifugeNavOracle(address(0), MAX_PRICE_AGE, address(usdc), address(jtrsy));
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new CentrifugeNavOracle(address(vault), MAX_PRICE_AGE, address(usdc), address(0));
    }

    function testRevert_constructor_zeroMaxPriceAge() public {
        vm.expectRevert(CentrifugeNavOracle.MaxPriceAgeIsZero.selector);
        new CentrifugeNavOracle(address(vault), 0, address(usdc), address(jtrsy));
    }

    /// @dev A vault of another share token is refused: 1,000 JTRSY must not be priced at the NAV of another class.
    function testRevert_constructor_shareTokenMismatch() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 6);
        vm.expectRevert(
            abi.encodeWithSelector(CentrifugeNavOracle.ShareTokenMismatch.selector, address(jtrsy), address(other))
        );
        new CentrifugeNavOracle(address(vault), MAX_PRICE_AGE, address(usdc), address(other));
    }

    /// @dev A vault of another asset is refused: its conversion would be in units of a token the market does not lend.
    function testRevert_constructor_assetMismatch() public {
        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 6);
        vm.expectRevert(
            abi.encodeWithSelector(CentrifugeNavOracle.AssetMismatch.selector, address(usdc), address(usdt))
        );
        new CentrifugeNavOracle(address(vault), MAX_PRICE_AGE, address(usdt), address(jtrsy));
    }

    /// @dev A stamp exactly `MAX_PRICE_AGE` old is returned; one second older is refused, by `price()` and by
    ///      `updateAnchor()`, with the vault's stamp.
    function test_price_maxPriceAgeEdge() public {
        CentrifugeNavOracle oracle = _deploy(6);
        vault.setPriceAge(MAX_PRICE_AGE);
        assertEq(oracle.price(), uint256(JTRSY_PRICE) * 1e18, "a price on the edge");
        vault.setPriceAge(MAX_PRICE_AGE + 1);
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
        vault.setPriceAhead(1);
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
        vault.setPriceAge(MAX_PRICE_AGE + 1);
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

    /// @dev The adapter keeps `maxPriceAge` in its own getter.
    function test_constructor_maxPriceAge() public {
        CentrifugeNavOracle impl = new CentrifugeNavOracle(address(vault), 3 days, address(usdc), address(jtrsy));
        assertEq(impl.MAX_PRICE_AGE(), 3 days, "MAX_PRICE_AGE");
    }

    /// @dev A 6-decimal share in a 6-decimal market scales by 1e18: one base unit of share is 1.123 base units of USDC.
    ///      The current price is the vault's 18-decimal price, not its 6-decimal `pricePerShare()`.
    function test_price_sixDecimalShare() public {
        CentrifugeNavOracle oracle = _deploy(6);
        assertEq(address(oracle.VAULT()), address(vault), "VAULT");
        assertEq(oracle.MAX_PRICE_AGE(), MAX_PRICE_AGE, "MAX_PRICE_AGE");
        assertEq(oracle.PRICE_SCALE(), 1e18, "PRICE_SCALE");
        assertEq(oracle.price(), uint256(JTRSY_PRICE) * 1e18, "price");
        assertEq(oracle.anchorPrice(), JTRSY_PRICE, "anchor is the 18-decimal share price");
    }

    /// @dev Any share decimals up to 18 above the loan token's, and any share price that the oracle can store: the
    ///      price is the share price times `10^(36 + 6 − shareDecimals − 18)`. At 24 decimals the adapter converts
    ///      `10^36` share units, which the vault's `uint128` cast still takes.
    function testFuzz_price_scalesToShareDecimals(uint8 shareDecimals, uint128 sharePrice) public {
        shareDecimals = uint8(bound(shareDecimals, 0, 24));
        sharePrice = uint128(bound(sharePrice, 1, type(uint104).max));
        vault.setCurrentPrice(sharePrice);
        CentrifugeNavOracle oracle = _deploy(shareDecimals);
        uint256 scale = TrailingAnchorOracleModel.priceScale(6, shareDecimals);
        assertEq(oracle.PRICE_SCALE(), scale, "PRICE_SCALE");
        assertEq(oracle.price(), uint256(sharePrice) * scale, "price");
    }

    function _deploy(uint8 shareDecimals) internal returns (CentrifugeNavOracle) {
        MockERC20 share = new MockERC20("Share", "SHARE", shareDecimals);
        vault.setShare(address(share));
        CentrifugeNavOracle impl = new CentrifugeNavOracle(address(vault), MAX_PRICE_AGE, address(usdc), address(share));
        bytes memory init = TrailingAnchorOracleModel.initializeCall(address(this));
        return CentrifugeNavOracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }
}
