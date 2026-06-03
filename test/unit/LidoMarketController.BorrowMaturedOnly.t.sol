// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

import {LidoMarketController} from "../../src/controllers/LidoMarketController.sol";
import {MarketAccessRegistry} from "../../src/controllers/MarketAccessRegistry.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {LidoMarketControllerHarness} from "../shared/LidoMarketControllerHarness.sol";

contract MockOracle {
    function price() external pure returns (uint256) {
        return 1e36; // ORACLE_PRICE_SCALE: 1:1 collateral/loan
    }
}

/// @dev Minimal Morpho core stub exposing only what the borrow path reads.
contract MockMorphoCore {
    address public immutable oracle;
    uint256 public immutable lltv;

    constructor(address oracle_, uint256 lltv_) {
        oracle = oracle_;
        lltv = lltv_;
    }

    function market(Id) external pure returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        return (0, 0, 0, 0, 0, 0);
    }

    function position(Id, address) external pure returns (uint256, uint128, uint128) {
        return (0, 0, 0); // no prior debt
    }

    function idToMarketParams(Id) external view returns (address, address, address, address, uint256) {
        return (address(0), address(0), oracle, address(0), lltv);
    }
}

/// @dev The borrow ceiling uses matured collateral only: maturing collateral never backs new
///      borrowing. With lltv = 0.8 and a 1:1 price, matured M allows borrowing up to 0.8*M.
contract LidoMarketControllerBorrowMaturedOnlyTest is Test {
    LidoMarketControllerHarness internal harness;

    Id internal constant MARKET = Id.wrap(bytes32(uint256(1)));
    uint64 internal constant MAX_DELAY = 2 hours;
    address internal user = address(0xABCD);

    function setUp() public {
        MockOracle oracle = new MockOracle();
        MockMorphoCore core = new MockMorphoCore(address(oracle), 0.8e18);

        MarketAccessRegistry registry = new MarketAccessRegistry(address(this));
        LidoMarketControllerHarness impl = new LidoMarketControllerHarness();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,bytes32,address,address)",
            address(core),
            Id.unwrap(MARKET),
            address(registry),
            address(this)
        );
        OssifiableProxy proxy = new OssifiableProxy(address(impl), address(this), initData);
        harness = LidoMarketControllerHarness(payable(address(proxy)));

        vm.warp(1_700_000_000);
    }

    function _mature(address u, uint256 amount) internal {
        harness.exposed_handleSupplyCollateral(MARKET, u, u, amount);
        skip(MAX_DELAY + 1);
        harness.exposed_syncMaturation(MARKET, u);
    }

    function test_BorrowWithinMaturedCeilingSucceeds() public {
        _mature(user, 100e18); // matured = 100e18 => maxBorrow = 80e18
        harness.exposed_handleBorrow(MARKET, user, user, user, 50e18); // <= 80e18, no revert
    }

    function test_BorrowAgainstMaturingOnlyReverts() public {
        harness.exposed_handleSupplyCollateral(MARKET, user, user, 100e18); // maturing, matured = 0
        vm.expectRevert(LidoMarketController.InsufficientMaturedCollateral.selector);
        harness.exposed_handleBorrow(MARKET, user, user, user, 50e18);
    }

    function test_BorrowExceedingMaturedCeilingReverts() public {
        _mature(user, 100e18); // maxBorrow = 80e18
        vm.expectRevert(LidoMarketController.InsufficientMaturedCollateral.selector);
        harness.exposed_handleBorrow(MARKET, user, user, user, 90e18); // > 80e18
    }
}
