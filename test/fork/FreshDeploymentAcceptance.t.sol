// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, Position, IMorpho} from "@lido-lend/src/interfaces/IMorpho.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {ForkFixture} from "../setup/ForkFixture.sol";
import {DeploymentSnapshot} from "../../script/deployment/DeploymentTypes.sol";
import {MarketMotionReadinessAcceptance} from "../acceptance/MarketMotionReadiness.t.sol";
import {MarketActivatedAcceptance} from "../acceptance/MarketActivated.t.sol";

contract FreshMarketReadinessAcceptance is MarketMotionReadinessAcceptance {
    bytes private fixtureRecord;

    function setUp() public override {
        if (bytes(vm.envOr("DEPLOYMENT_RUN", string(""))).length != 0) {
            vm.skip(true, "use acceptance-run for a recorded deployment");
        }
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), pin);
        vm.recordLogs();
        DeploymentSnapshot memory d = (new ForkFixture()).prepareInert();
        fixtureRecord = abi.encode(d);
        _bindTypedDeployment(d, 0, d.protocol.agent, true, address(0));
    }

    function test_secondMarketIsReadyIndependently() public {
        DeploymentSnapshot memory d = abi.decode(fixtureRecord, (DeploymentSnapshot));
        _bindTypedDeployment(d, 1, d.protocol.agent, true, address(0));
        this.test_deployedInertAndReadyForMotion();
    }
}

contract FreshMarketActivatedAcceptance is MarketActivatedAcceptance {
    bytes private fixtureRecord;

    function setUp() public override {
        if (bytes(vm.envOr("DEPLOYMENT_RUN", string(""))).length != 0) {
            vm.skip(true, "use acceptance-run for a recorded deployment");
        }
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), pin);
        vm.recordLogs();
        DeploymentSnapshot memory d = (new ForkFixture()).prepare();
        fixtureRecord = abi.encode(d);
        _bindTypedDeployment(d, 0, d.protocol.agent, true, d.protocol.agent);
        _expectFunding(0, 1e9, 1e9);
    }

    function test_reviewedSteward_matchesActivatedMarket() public {
        _expectMarketSteward(agent);
        _assertRoles();
    }

    function testRevert_wrongReviewedSteward_isRejected() public {
        _expectMarketSteward(makeAddr("wrongReviewedSteward"));
        vm.expectRevert();
        this.test_fullyConnectedConfiguredAndLive();
    }

    function test_reviewedNonzeroFee_isAccepted() public {
        vm.prank(executor);
        LidoLendOwner(facade).setFee(_params(), 0.1e18);
        _expectFunding(0.1e18, 1e9, 1e9);
        this.test_fullyConnectedConfiguredAndLive();
    }

    function testRevert_wrongFee_isRejected() public {
        vm.prank(executor);
        LidoLendOwner(facade).setFee(_params(), 0.1e18);
        vm.expectRevert();
        this.test_fullyConnectedConfiguredAndLive();
    }

    function testRevert_missingCorePreseed_isRejected() public {
        vm.mockCall(
            core,
            abi.encodeCall(IMorpho.position, (Id.wrap(marketId), PRESEED_RECIPIENT)),
            abi.encode(Position({supplyShares: 0, borrowShares: 0, collateral: 0}))
        );
        vm.expectRevert();
        this.test_fullyConnectedConfiguredAndLive();
    }

    function testRevert_insufficientVaultPreseed_isRejected() public {
        vm.mockCall(
            vault, abi.encodeWithSignature("balanceOf(address)", PRESEED_RECIPIENT), abi.encode(uint256(1e9 - 1))
        );
        vm.expectRevert();
        this.test_fullyConnectedConfiguredAndLive();
    }

    function test_seedThresholdBoundary_isAccepted() public {
        vm.mockCall(vault, abi.encodeWithSignature("balanceOf(address)", PRESEED_RECIPIENT), abi.encode(uint256(1e9)));
        this.test_fullyConnectedConfiguredAndLive();
    }

    function test_secondMarketIsActivatedIndependently() public {
        DeploymentSnapshot memory d = abi.decode(fixtureRecord, (DeploymentSnapshot));
        _bindTypedDeployment(d, 1, d.protocol.agent, true, d.protocol.agent);
        this.test_fullyConnectedConfiguredAndLive();
    }
}
