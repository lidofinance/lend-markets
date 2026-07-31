// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";

contract CircuitBreakerConfigStub {
    address public immutable ADMIN;

    constructor(address admin) {
        ADMIN = admin;
    }
}

contract ProtocolDeployerHarness is ProtocolDeployer {
    function requireCircuitBreakerPolicy(address circuitBreaker, address executor) external view {
        _requireCircuitBreakerPolicy(circuitBreaker, executor);
    }

    function requireUniqueMarketIds(string[] memory names, LidoLendMarketFactory.MarketSpec[] memory markets)
        external
        pure
    {
        _requireUniqueMarketIds(names, markets);
    }
}

contract ProtocolDeployerTest is Test {
    ProtocolDeployerHarness internal deployer;
    address internal executor;

    function setUp() external {
        deployer = new ProtocolDeployerHarness();
        executor = makeAddr("executor");
    }

    function testRevert_requireCircuitBreakerPolicy_missingCircuitBreaker() external {
        vm.expectRevert(ProtocolDeployer.MissingCircuitBreaker.selector);
        deployer.requireCircuitBreakerPolicy(address(0), executor);
    }

    function testRevert_requireCircuitBreakerPolicy_rejectsNonContract() external {
        address circuitBreaker = makeAddr("circuitBreaker");
        vm.expectRevert(abi.encodeWithSelector(ProtocolDeployer.CircuitBreakerNotContract.selector, circuitBreaker));
        deployer.requireCircuitBreakerPolicy(circuitBreaker, executor);
    }

    function testRevert_requireCircuitBreakerPolicy_rejectsWrongAdmin() external {
        address actualAdmin = makeAddr("actualAdmin");
        address circuitBreaker = address(new CircuitBreakerConfigStub(actualAdmin));
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolDeployer.UnexpectedCircuitBreakerAdmin.selector, executor, actualAdmin)
        );
        deployer.requireCircuitBreakerPolicy(circuitBreaker, executor);
    }

    function test_requireCircuitBreakerPolicy_acceptsExecutorAdministeredCircuitBreaker() external {
        deployer.requireCircuitBreakerPolicy(address(new CircuitBreakerConfigStub(executor)), executor);
    }

    function testRevert_requireUniqueMarketIds_duplicateEconomicInputs() external {
        string[] memory names = new string[](2);
        names[0] = "market-a";
        names[1] = "market-b";
        LidoLendMarketFactory.MarketSpec[] memory markets = new LidoLendMarketFactory.MarketSpec[](2);
        markets[0] = _marketSpec(0.8 ether);
        markets[1] = _marketSpec(0.8 ether);

        vm.expectRevert(abi.encodeWithSelector(ProtocolDeployer.DuplicateMarketId.selector, names[0], names[1]));
        deployer.requireUniqueMarketIds(names, markets);
    }

    function test_requireUniqueMarketIds_acceptsDifferentLltv() external view {
        string[] memory names = new string[](2);
        names[0] = "market-a";
        names[1] = "market-b";
        LidoLendMarketFactory.MarketSpec[] memory markets = new LidoLendMarketFactory.MarketSpec[](2);
        markets[0] = _marketSpec(0.8 ether);
        markets[1] = _marketSpec(0.75 ether);

        deployer.requireUniqueMarketIds(names, markets);
    }

    function _marketSpec(uint256 lltv) private pure returns (LidoLendMarketFactory.MarketSpec memory market) {
        market.loanToken = address(0x1001);
        market.collateralToken = address(0x1002);
        market.oracle = address(0x1003);
        market.lltv = lltv;
    }
}
