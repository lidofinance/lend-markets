// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {LidoLendPrimitives} from "../../script/lib/LidoLendPrimitives.sol";

/// @dev Deploys the oracle through the same `_behindProxy` call and init payload as `DeployUsdyOracle.run`.
contract UsdyOracleDeployHarness is LidoLendPrimitives {
    function deploy(
        address usdyOracle,
        uint256 minPrice,
        uint256 maxPrice,
        address feed,
        address loanToken,
        address admin
    ) external returns (address) {
        address implementation = address(new UsdyStableOracle(usdyOracle, minPrice, maxPrice));
        return _behindProxy(implementation, admin, abi.encodeCall(UsdyStableOracle.initialize, (feed, loanToken)));
    }
}

contract DeployUsdyDecimalsMock {
    uint8 public immutable decimals;

    constructor(uint8 value) {
        decimals = value;
    }
}

contract DeployUsdyNavMock {
    function getPrice() external pure returns (uint256) {
        return 1.05 ether;
    }
}

contract DeployUsdyOracleTest is Test {
    /// @dev A stranger cannot call `initialize` on a deployed `UsdyStableOracle` proxy and bind another feed or
    ///      another loan token. `DeployUsdyOracle.run` passes the init data to `_behindProxy`, so the proxy is
    ///      initialized in the call that creates it. A later `initialize` reverts with `InvalidInitialization`.
    ///      `initialize` itself has no caller check. The other initializable proxies from
    ///      `LidoLendPrimitives._behindProxy` and `LidoLendMarketFactory` also get their init data at creation. The
    ///      `WstEthRateOracle` proxy gets empty data, and it has no initializer.
    function testRevert_strangerInitializeAfterDeploy_invalidInitialization() external {
        address feed = address(new DeployUsdyDecimalsMock(8));
        address strangerFeed = address(new DeployUsdyDecimalsMock(8));
        address loanToken = address(new DeployUsdyDecimalsMock(6));
        UsdyOracleDeployHarness harness = new UsdyOracleDeployHarness();
        UsdyStableOracle oracle = UsdyStableOracle(
            harness.deploy(address(new DeployUsdyNavMock()), 0.5e24, 10e24, feed, loanToken, makeAddr("agent"))
        );
        assertEq(address(oracle.stableUsdFeed()), feed, "setup: configured feed bound at deploy");

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(strangerFeed, loanToken);

        assertEq(address(oracle.stableUsdFeed()), feed, "configured feed kept");
        // 10^(36 + 6 loan + 8 feed - 18 USDY - 18 NAV) = 1e14.
        assertEq(oracle.scale(), 1e14, "configured scale kept");
    }
}
