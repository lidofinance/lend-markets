// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {DeployWethWsteth} from "../../script/deployment/mainnet/DeployWethWsteth.s.sol";
import {
    ProtocolAddresses,
    MarketPlan,
    MarketDeploymentResult,
    MarketActivation
} from "../../script/deployment/DeploymentTypes.sol";
import {
    MarketPreparation,
    IPreparationIrm,
    IPreparationRouter,
    IPreparationOwner
} from "../setup/MarketPreparation.sol";
import {ForkFixture} from "../setup/ForkFixture.sol";
import {DeploymentSnapshot} from "../../script/deployment/DeploymentSnapshot.sol";
import {ForkStack} from "../fork/helpers/ForkStack.sol";

contract IncorrectPriceFeed {
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    function price() external pure returns (uint256) {
        return 1e36;
    }
}

contract MarketPreparationTest is ForkStack, MarketPreparation, DeployWethWsteth {
    BoundMarket internal m;
    ProtocolAddresses internal protocolAddresses;
    MarketPlan internal plan;
    MarketDeploymentResult internal deployment;
    MarketActivation internal activation;

    function setUp() public {
        _selectSourceFork();
        DeploymentSnapshot memory d = (new ForkFixture()).prepare();
        _useDeployment(d);
        m = _bindMarket(_marketForRole("weth-wsteth"));
        protocolAddresses = d.protocol;
        plan = d.markets[0].plan;
        deployment = d.markets[0].contracts;
        activation = MarketActivation({
            pauser: d.protocol.agent, steward: d.protocol.agent, enableSettlement: true, exitBooks: d.books
        });
    }

    function test_prepareActiveMarket_keepsStateAndAddresses() public {
        _setSupplyCap(m, 123 ether);
        bytes32 beforeMarket = keccak256(abi.encode(m.core.market(m.id)));
        uint256 beforeNonce = vm.getNonce(address(this));
        MarketDeploymentResult memory prepared = _prepareMarket(protocolAddresses, plan, deployment, activation);
        assertEq(keccak256(abi.encode(prepared)), keccak256(abi.encode(deployment)));
        assertEq(keccak256(abi.encode(m.core.market(m.id))), beforeMarket);
        assertEq(vm.getNonce(address(this)), beforeNonce);
        assertEq(m.controller.supplyCap(), 123 ether);
    }

    function test_prepareInertMarket_reusesSharedDependencies() public {
        MarketPlan memory next = plan;
        next.market.oracle = deployment.params.oracle;
        next.market.guardianSignals = deployment.guardianSignals;
        next.market.lltv = 0.935e18;
        MarketDeploymentResult memory inert = _deployMarket(protocolAddresses, next);
        assertEq(ILidoLend(protocolAddresses.core).market(inert.id).lastUpdate, 0);
        MarketDeploymentResult memory prepared = _prepareMarket(protocolAddresses, next, inert, activation);
        assertEq(prepared.controller, inert.controller);
        assertEq(prepared.vault, inert.vault);
        assertEq(prepared.guardianSignals, deployment.guardianSignals);
        assertEq(prepared.params.oracle, deployment.params.oracle);
        assertTrue(ILidoLend(protocolAddresses.core).market(prepared.id).lastUpdate != 0);
    }

    function testRevert_recordedContractMissing() public {
        MarketDeploymentResult memory broken = deployment;
        broken.controller = makeAddr("missing.controller");
        vm.expectRevert(abi.encodeWithSelector(MissingCode.selector, broken.controller));
        this.prepareRecorded(broken);
    }

    function testRevert_partialRecordDoesNotDeployReplacement() public {
        MarketDeploymentResult memory broken;
        broken.vault = deployment.vault;
        vm.expectRevert("Partial market record");
        this.prepareRecorded(broken);
    }

    function testRevert_recordDoesNotMatchMarketPlan() public {
        MarketPlan memory wrong = plan;
        wrong.market.lltv = 0.9e18;
        vm.expectRevert("Market LLTV differs from plan");
        this.preparePlan(wrong, deployment);
    }

    function testRevert_unseededCreatedMarketIsNotRepaired() public {
        MarketPlan memory next = plan;
        next.market.oracle = deployment.params.oracle;
        next.market.guardianSignals = deployment.guardianSignals;
        next.market.lltv = 0.93e18;
        MarketDeploymentResult memory incomplete = _deployMarket(protocolAddresses, next);
        vm.startPrank(protocolAddresses.executor);
        IPreparationIrm(protocolAddresses.adaptiveCurveIrm).applyIrmConfig(incomplete.params, incomplete.irmConfig);
        IPreparationRouter(protocolAddresses.irmRouter)
            .setMarketIrm(incomplete.params, protocolAddresses.adaptiveCurveIrm);
        IPreparationOwner(protocolAddresses.ownerFacade).createMarket(incomplete.params, incomplete.controller, true);
        vm.stopPrank();
        vm.expectRevert("Missing core seed");
        this.preparePlan(next, incomplete);
    }

    function testRevert_unconfiguredCommitteeCannotDeploy() public {
        MarketPlan memory unconfigured = _wethWstethPlan(new address[](0));
        MarketDeploymentResult memory empty;
        vm.expectRevert(MissingCommittee.selector);
        this.preparePlan(unconfigured, empty);
    }

    function testRevert_inertCurveDiffersFromReviewedPlan() public {
        MarketPlan memory next = plan;
        next.market.oracle = deployment.params.oracle;
        next.market.guardianSignals = deployment.guardianSignals;
        next.market.lltv = 0.92e18;
        MarketDeploymentResult memory inert = _deployMarket(protocolAddresses, next);
        next.curve.initialRateAtTarget += 1;
        vm.expectRevert("Inert curve differs from plan");
        this.preparePlan(next, inert);
    }

    function testRevert_inertActivationDiffersFromReviewedPlan() public {
        MarketPlan memory next = plan;
        next.market.oracle = deployment.params.oracle;
        next.market.guardianSignals = deployment.guardianSignals;
        next.market.lltv = 0.92e18;
        MarketDeploymentResult memory inert = _deployMarket(protocolAddresses, next);
        next.market.activationConfig.minActivationDelay += 1;
        vm.expectRevert("Inert activation differs from plan");
        this.preparePlan(next, inert);
    }

    function testRevert_reusedPriceFeedHasDifferentImplementation() public {
        address implementation = address(new IncorrectPriceFeed());
        MarketPlan memory next = plan;
        next.market.oracle = address(new OssifiableProxy(implementation, protocolAddresses.agent, ""));
        MarketDeploymentResult memory empty;
        vm.expectRevert(abi.encodeWithSelector(PriceFeedCodeMismatch.selector, implementation));
        this.preparePlan(next, empty);
    }

    function test_prepareMarket_withoutOptionalExitBooks() public {
        ProtocolAddresses memory p = protocolAddresses;
        MarketActivation memory withoutBooks = activation;
        delete withoutBooks.exitBooks;
        MarketPlan memory next = plan;
        next.market.oracle = deployment.params.oracle;
        next.market.guardianSignals = deployment.guardianSignals;
        next.market.lltv = 0.92e18;
        MarketDeploymentResult memory empty;
        MarketDeploymentResult memory added = _prepareMarket(p, next, empty, withoutBooks);
        assertTrue(ILidoLend(p.core).market(added.id).lastUpdate != 0);
        assertGe(ILidoLendERC4626(added.vault).balanceOf(SEED_RECIPIENT), MIN_SEED_SHARES);
    }

    function testFuzz_prepareAdditionalMarket_preservesActiveMarket(uint64 rawLltv) public {
        bytes32 initialMarket = keccak256(abi.encode(m.core.market(m.id)));
        MarketPlan memory next = plan;
        next.market.oracle = deployment.params.oracle;
        next.market.guardianSignals = deployment.guardianSignals;
        next.market.lltv = bound(uint256(rawLltv), 0.5e18, 0.939e18);
        MarketDeploymentResult memory empty;
        MarketDeploymentResult memory added = _prepareMarket(protocolAddresses, next, empty, activation);
        assertTrue(Id.unwrap(added.id) != Id.unwrap(deployment.id));
        assertEq(keccak256(abi.encode(m.core.market(m.id))), initialMarket);
        assertEq(added.guardianSignals, deployment.guardianSignals);
        assertEq(
            keccak256(abi.encode(_prepareMarket(protocolAddresses, next, added, activation))),
            keccak256(abi.encode(added))
        );
    }

    function testRevert_wrongExecutorDoesNotRepairRoles() public {
        ProtocolAddresses memory wrong = protocolAddresses;
        wrong.executor = makeAddr("wrong.executor");
        vm.expectRevert(
            abi.encodeWithSelector(
                IncompatibleDependency.selector, bytes32("router.manager"), wrong.executor, protocolAddresses.executor
            )
        );
        this.checkProtocol(wrong);
    }

    function prepareRecorded(MarketDeploymentResult memory recorded) external {
        _prepareMarket(protocolAddresses, plan, recorded, activation);
    }

    function preparePlan(MarketPlan memory input, MarketDeploymentResult memory recorded) external {
        _prepareMarket(protocolAddresses, input, recorded, activation);
    }

    function checkProtocol(ProtocolAddresses memory p) external view {
        _checkProtocol(p);
    }
}
