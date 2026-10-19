// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {UsdyOracle} from "../../src/oracle/UsdyOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {MockERC20, MockNavOracle, MockUsdFeed} from "../setup/Mocks.sol";
import {NavOracleModel} from "../setup/NavOracleModel.sol";

/// @notice `UsdyOracle` reads Ondo's 18-decimal USD getter and scales it to the market's loan token.
contract UsdyOracleTest is Test {
    MockNavOracle internal getter;
    MockUsdFeed internal feed;
    MockERC20 internal usdy;

    function setUp() public {
        vm.warp(1_760_000_000);
        getter = new MockNavOracle();
        feed = new MockUsdFeed();
        usdy = new MockERC20("USDY", "USDY", 18);
    }

    function testRevert_constructor_zeroSource() public {
        MockERC20 usdc = new MockERC20("USDC", "USDC", 6);
        vm.expectRevert(NavOracleBase.ZeroAddress.selector);
        new UsdyOracle(address(0), address(usdc), address(usdy), address(feed));
    }

    /// @dev A NAV of 1.15 USD prices one USDY at 1.15 USDC: `1.15e18 × 10^(36 + 6 − 18 − 18) = 1.15e24`.
    function test_price_usdcExample() public {
        getter.setPrice(1.15e18);
        UsdyOracle oracle = _deploy(6);
        assertEq(oracle.PRICE_SCALE(), 1e6, "PRICE_SCALE");
        assertEq(address(oracle.SOURCE()), address(getter), "SOURCE");
        assertEq(oracle.price(), 1.15e24, "1.15 USDC per USDY");
    }

    /// @dev Any loan token decimals: the price is the NAV times `10^(36 + loanDecimals − 18 − 18)`.
    function testFuzz_price_scalesToLoanDecimals(uint8 loanDecimals, uint256 nav) public {
        loanDecimals = uint8(bound(loanDecimals, 0, 24));
        nav = bound(nav, 1, 1e24);
        getter.setPrice(nav);
        UsdyOracle oracle = _deploy(loanDecimals);
        uint256 scale = 10 ** uint256(loanDecimals);
        assertEq(oracle.PRICE_SCALE(), scale, "PRICE_SCALE");
        assertEq(oracle.price(), nav * scale, "price");
        assertEq(oracle.referencePrice(), nav * scale, "seeded in the returned domain");
    }

    function testRevert_price_sourceFailureBubbles() public {
        getter.setPrice(1.15e18);
        UsdyOracle oracle = _deploy(6);
        getter.setDown(true);
        vm.expectRevert(MockNavOracle.NavOracleDown.selector);
        oracle.price();
    }

    function _deploy(uint8 loanDecimals) internal returns (UsdyOracle) {
        MockERC20 loan = new MockERC20("Loan", "LOAN", loanDecimals);
        UsdyOracle impl = new UsdyOracle(address(getter), address(loan), address(usdy), address(feed));
        bytes memory init =
            abi.encodeCall(NavOracleBase.initialize, (address(this), NavOracleModel.workingDefaults(0.0375e18)));
        return UsdyOracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }
}
