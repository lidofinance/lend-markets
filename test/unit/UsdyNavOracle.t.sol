// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";

/// @notice `UsdyNavOracle` reads Ondo's 18-decimal USD getter as its current price, and the base scales it to the
///         market's tokens. The anchor rules run through this adapter in `TrailingAnchorOracleBase.t.sol`.
contract UsdyNavOracleTest is Test {
    MockOndoPriceGetter internal getter;
    MockERC20 internal usdy;
    MockERC20 internal usdc;

    function setUp() public {
        vm.warp(1_760_000_000);
        getter = new MockOndoPriceGetter();
        usdy = new MockERC20("Ondo US Dollar Yield", "USDY", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    function testRevert_constructor_zeroAddresses() public {
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new UsdyNavOracle(address(0), address(usdc), address(usdy));
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new UsdyNavOracle(address(getter), address(usdc), address(0));
    }

    /// @dev A NAV of 1.15 USD prices one USDY at 1.15 USDC: `1.15e18 × 10^(36 + 6 − 18 − 18) = 1.15e24`. The
    ///      anchor keeps the getter's own 18-decimal value.
    function test_price_usdcExample() public {
        getter.setCurrentPrice(1.15e18);
        UsdyNavOracle oracle = _deploy(usdc);
        assertEq(address(oracle.SOURCE()), address(getter), "SOURCE");
        assertEq(oracle.PRICE_SCALE(), 1e6, "PRICE_SCALE");
        assertEq(oracle.price(), 1.15e24, "1.15 USDC per USDY");
        assertEq(oracle.anchorPrice(), 1.15e18, "anchor in the getter's decimals");
    }

    /// @dev The base's scale rule through the adapter whose collateral decimals are free:
    ///      `PRICE_SCALE = 10^(36 + loanDecimals − collateralDecimals − 18)`, refused when the exponent is
    ///      negative.
    function testFuzz_constructor_priceScale(uint8 loanDecimals, uint8 collateralDecimals) public {
        loanDecimals = uint8(bound(loanDecimals, 0, 36));
        collateralDecimals = uint8(bound(collateralDecimals, 0, 60));
        MockERC20 loanToken = new MockERC20("L", "L", loanDecimals);
        MockERC20 collateralToken = new MockERC20("C", "C", collateralDecimals);
        if (uint256(collateralDecimals) + 18 > 36 + uint256(loanDecimals)) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    TrailingAnchorOracleBase.UnsupportedDecimals.selector, loanDecimals, collateralDecimals
                )
            );
            new UsdyNavOracle(address(getter), address(loanToken), address(collateralToken));
            return;
        }
        UsdyNavOracle impl = new UsdyNavOracle(address(getter), address(loanToken), address(collateralToken));
        assertEq(
            impl.PRICE_SCALE(), TrailingAnchorOracleModel.priceScale(loanDecimals, collateralDecimals), "PRICE_SCALE"
        );
    }

    /// @dev Any loan token decimals: the price is the getter's value times `10^loanDecimals`, while the anchor stays
    ///      the getter's value.
    function testFuzz_price_scalesToLoanDecimals(uint8 loanDecimals, uint256 nav) public {
        loanDecimals = uint8(bound(loanDecimals, 0, 24));
        nav = bound(nav, 1, 1e24);
        getter.setCurrentPrice(nav);
        UsdyNavOracle oracle = _deploy(new MockERC20("Loan", "LOAN", loanDecimals));
        assertEq(oracle.price(), nav * 10 ** uint256(loanDecimals), "price");
        assertEq(oracle.anchorPrice(), nav, "anchor unscaled");
    }

    function _deploy(MockERC20 loan) internal returns (UsdyNavOracle) {
        UsdyNavOracle impl = new UsdyNavOracle(address(getter), address(loan), address(usdy));
        bytes memory init = TrailingAnchorOracleModel.initializeCall(address(this));
        return UsdyNavOracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }
}
