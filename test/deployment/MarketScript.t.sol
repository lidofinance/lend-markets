// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {DeployBundlerBase} from "../../script/deployment/DeployBundlerBase.s.sol";
import {DeployCoreBase} from "../../script/deployment/DeployCoreBase.s.sol";
import {DeployExitBooksBase} from "../../script/deployment/DeployExitBooksBase.s.sol";
import {
    DeployMarketBase,
    MarketDeploymentResult,
    MarketDeployConfig
} from "../../script/deployment/DeployMarketBase.s.sol";
import {ProtocolAddresses} from "../../script/lib/ProtocolDeployer.sol";
import {ForkStack, IEVMScriptExecutor} from "../fork/helpers/ForkStack.sol";

contract IncorrectPriceFeed {
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    function price() external pure returns (uint256) {
        return 1e36;
    }
}

contract UnexpectedPriceFeedProxy {
    address private immutable ADMIN;

    constructor(address admin) {
        ADMIN = admin;
    }

    function proxy__getAdmin() external view returns (address) {
        return ADMIN;
    }

    function proxy__getImplementation() external pure returns (address) {
        return address(0);
    }
}

interface IReadPauser {
    function getPauser(address pausable) external view returns (address);
}

interface IReadIrmRoute {
    function marketIrm(bytes32 id) external view returns (address);
}

/// @notice A market script on the default fork, mainnet `weth-wsteth`, where the market is deployed and not created
///         and Easy Track has no activation factory: `deploy` refuses a wrong protocol or reused oracle, and the
///         activation EVMScript creates a market through the EVMScriptExecutor.
contract MarketScriptTest is ForkStack {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    function setUp() public {
        _forkTarget(false);
        if (parameters.market.collateralToken != WSTETH) vm.skip(true, "MarketScript: a wstETH market's script");
    }

    /// @dev The script's activation EVMScript, sent by Easy Track to the EVMScriptExecutor, creates the market with
    ///      its IRM route, pauser and steward, whether or not Easy Track registers the activation factory.
    function test_activationScript_createsTheMarketThroughTheExecutor() public {
        MarketDeploymentResult memory d = deployment;
        if (ILidoLend(protocol.core).market(d.id).lastUpdate != 0) {
            vm.skip(true, "MarketScript: the market is already created");
        }
        IEVMScriptExecutor executor = IEVMScriptExecutor(protocol.executor);
        bytes memory evmScript = script.activationScript(protocol, d);
        vm.prank(executor.easyTrack());
        executor.executeEVMScript(evmScript);
        assertEq(ILidoLend(protocol.core).marketController(d.id), d.controller, "controller");
        assertEq(IReadIrmRoute(protocol.irmRouter).marketIrm(Id.unwrap(d.id)), protocol.adaptiveCurveIrm, "IRM route");
        assertEq(
            IReadPauser(protocol.circuitBreaker).getPauser(d.controller),
            script.getActivationMotionConfig().pauser,
            "pauser"
        );
        assertTrue(
            IRiskStewardDashboard(protocol.dashboard).isMarketSteward(d.id, script.getActivationMotionConfig().steward),
            "steward"
        );
    }

    function test_createMarket_withoutExitBooks() public {
        MarketDeploymentResult memory added = _deploySecondMarket(0.92e18);
        delete books;
        _createMarket(added);
        assertTrue(ILidoLend(protocol.core).market(added.id).lastUpdate != 0);
    }

    function testFuzz_secondMarket_leavesTheFirstAsItIs(uint64 rawLltv) public {
        ILidoLend core = ILidoLend(protocol.core);
        bytes32 first = keccak256(abi.encode(core.market(deployment.id)));
        MarketDeploymentResult memory added = _deploySecondMarket(bound(uint256(rawLltv), 0.5e18, 0.939e18));
        _createMarket(added);
        assertTrue(Id.unwrap(added.id) != Id.unwrap(deployment.id));
        assertEq(keccak256(abi.encode(core.market(deployment.id))), first);
        assertEq(added.guardianSignals, deployment.guardianSignals);
    }

    /// @dev A recorded contract with no code at the block, as on a fork from before its deployment, fails each script
    ///      instead of being deployed again.
    function testRevert_getOrDeploy_recordWithoutCode() public {
        vm.etch(deployment.vault, "");
        vm.expectRevert(abi.encodeWithSelector(DeployMarketBase.MissingCode.selector, deployment.vault));
        script.getOrDeploy(protocol);
        vm.etch(books.morpho, "");
        vm.expectRevert(abi.encodeWithSelector(DeployExitBooksBase.MissingCode.selector, books.morpho));
        network.books.getOrDeploy(protocol);
        vm.etch(bundler.bundler, "");
        vm.expectRevert(abi.encodeWithSelector(DeployBundlerBase.MissingCode.selector, bundler.bundler));
        network.bundler.getOrDeploy(protocol);
        vm.etch(protocol.core, "");
        vm.expectRevert(abi.encodeWithSelector(DeployCoreBase.MissingCode.selector, protocol.core));
        network.core.getOrDeploy();
    }

    function testRevert_protocolOfAnotherExecutor() public {
        ProtocolAddresses memory wrong = protocol;
        wrong.executor = makeAddr("wrong.executor");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployMarketBase.IncompatibleDependency.selector,
                bytes32("router.manager"),
                wrong.executor,
                protocol.executor
            )
        );
        script.deploy(wrong, parameters);
    }

    function testRevert_noGuardianCommittee() public {
        MarketDeployConfig memory unconfigured = parameters;
        unconfigured.committee.guardians = new address[](0);
        vm.expectRevert(DeployMarketBase.MissingCommittee.selector);
        script.deploy(protocol, unconfigured);
    }

    function testRevert_reusedOracle_otherImplementation() public {
        address implementation = address(new IncorrectPriceFeed());
        MarketDeployConfig memory next = parameters;
        next.market.oracle = address(new OssifiableProxy(implementation, protocol.agent, ""));
        vm.expectRevert(abi.encodeWithSelector(DeployMarketBase.PriceFeedCodeMismatch.selector, implementation));
        script.deploy(protocol, next);
    }

    function testRevert_reusedOracle_otherProxyAdmin() public {
        MarketDeployConfig memory next = parameters;
        address wrongAdmin = makeAddr("wrong.priceFeedAdmin");
        address implementation = OssifiableProxy(payable(parameters.market.oracle)).proxy__getImplementation();
        next.market.oracle = address(new OssifiableProxy(implementation, wrongAdmin, ""));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployMarketBase.IncompatibleDependency.selector, bytes32("priceFeed.admin"), protocol.agent, wrongAdmin
            )
        );
        script.deploy(protocol, next);
    }

    function testRevert_reusedOracle_otherProxyCode() public {
        MarketDeployConfig memory next = parameters;
        next.market.oracle = address(new UnexpectedPriceFeedProxy(protocol.agent));
        vm.expectRevert(abi.encodeWithSelector(DeployMarketBase.PriceFeedCodeMismatch.selector, next.market.oracle));
        script.deploy(protocol, next);
    }

    function testRevert_reusedOracle_zeroPrice() public {
        vm.mockCall(WSTETH, abi.encodeWithSignature("getStETHByWstETH(uint256)", 1e36), abi.encode(uint256(0)));
        vm.expectRevert("Price feed is zero");
        script.deploy(protocol, parameters);
    }

    function testRevert_collateralOtherThanTheScripts() public {
        MarketDeployConfig memory next = parameters;
        next.market.collateralToken = WETH;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployMarketBase.IncompatibleDependency.selector, bytes32("collateralToken"), WSTETH, WETH
            )
        );
        script.deploy(protocol, next);
    }

    /// @dev The market at `lltv` over the same oracle and guardian registry, deployed and not created.
    function _deploySecondMarket(uint256 lltv) private returns (MarketDeploymentResult memory) {
        MarketDeployConfig memory next = parameters;
        next.market.lltv = lltv;
        return script.deploy(protocol, next);
    }
}
